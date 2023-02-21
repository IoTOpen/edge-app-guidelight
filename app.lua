-- Helper functions
local function matchCriteria(fn, criteria)
    local isArray = false
    local arrayMatch = false
    for k, v in pairs(criteria) do
        if math.type(k) ~= nil then
            isArray = true
            if fn.id == v then
                arrayMatch = true
                break
            end
        else
            if k == 'id' then
                if fn.id ~= v then
                    return false
                end
            elseif k == 'type' then
                if fn.type ~= v then
                    return false
                end
            elseif fn.meta[k] == nil then
                return false
            elseif fn.meta[k] ~= v then
                return false
            end
        end
    end
    if isArray then
        return arrayMatch
    end
    return true
end

local function findFunction(criteria)
    if math.type(criteria) ~= nil then
        for _, fn in ipairs(functions) do
            if fn.id == criteria then
                return fn
            end
        end
    elseif type(criteria) == 'table' then
        for _, fn in ipairs(functions) do
            if matchCriteria(fn, criteria) then
                return fn
            end
        end
    end
    return nil
end

local function findFunctions(criteria)
    local res = {}
    if type(criteria) == 'table' then
        for _, fn in ipairs(functions) do
            if matchCriteria(fn, criteria) then
                table.insert(res, fn)
            end
        end
    end
    return res
end

-- Real logic
local controlFunction
local triggerFunctions
local actuatorFunctions
local countdownTimer
local armed = true

function onControlMessage(topic, payload, retained)
    local data = json:decode(payload)
    if data.value == tonumber(controlFunction.meta.state_on) then
        armed = true
        local newMessage = { value = tonumber(controlFunction.meta.state_on), timestamp = edge:time() }
        mq:pub(controlFunction.meta.topic_read, json:encode(newMessage))
    elseif data.value == tonumber(controlFunction.meta.state_off) then
        armed = false
        local newMessage = { value = tonumber(controlFunction.meta.state_off), timestamp = edge:time() }
        mq:pub(controlFunction.meta.topic_read, json:encode(newMessage))
    end
end

function onTriggerMessage(topic, payload, retained)
    if not armed then
        return
    end
    local func = findFunction({
        topic_read = topic
    })
    if func == nil then
        return
    end
    local data = json:decode(payload)
    if data.value == tonumber(func.meta.state_movement) then
        if countdownTimer ~= nil then
            countdownTimer:cancel()
        end
        setActuatorsOn()
        countdownTimer = timer:after(cfg.time_on * 60, setActuatorsOff)
    end
end

function setActuatorsOff()
    for _, func in ipairs(actuatorFunctions) do
        local newMessage = { value = tonumber(func.meta.state_off), timestamp = edge:time() }
        mq:pub(func.meta.topic_write, json:encode(newMessage))
    end
end

function setActuatorsOn()
    for _, func in ipairs(actuatorFunctions) do
        local newMessage = { value = tonumber(func.meta.state_on), timestamp = edge:time() }
        mq:pub(func.meta.topic_write, json:encode(newMessage))
    end
end

-- State handling

function onCreate()
    if cfg.control_function == "yes" then
        local resp, err = lynx.createFunction({
            type = "switch",
            meta = {
                ["edge_app.id"] = tostring(app.id),
                state_on = "1",
                state_off = "0",
                topic_read = "obj/edge/guidelight_control/" .. tostring(app.id),
                topic_write = "set/obj/edge/guidelight_control/" .. tostring(app.id),
                name = app.name .. " - Control"
            }
        })
        if err ~= nil then
            log.d("%s", err.message)
        else
            log.d("Created new function: %s", resp.id)
            controlFunction = resp
        end
    end
end

function onDestroy()
    if cfg.control_function == "yes" and controlFunction ~= nil then
        lynx.deleteFunction(controlFunction.id)
    end
end

function onStart()
    if cfg.control_function == "yes" then
        if controlFunction == nil then
            controlFunction = findFunction({
                ["edge_app.id"] = tostring(app.id)
            })
        end
        if controlFunction == nil then
            log.d("Control function not found; removed?")
            return
        end

        -- Handle control messages
        mq:sub(controlFunction.meta.topic_write)
        mq:bind(controlFunction.meta.topic_write, onControlMessage)

        -- Set initial state to last state if any
        local resp, err = lynx.getStatus()
        if err ~= nil then
            log.d("Could not get status: %s", err.message)
        else
            local stat
            for _, st in pairs(resp) do
                if st.topic == controlFunction.meta.topic_read then
                    stat = st
                    break
                end
            end
            if stat ~= nil and stat.value == tonumber(controlFunction.meta.state_on) then
                armed = true
            elseif stat ~= nil and stat.value == tonumber(controlFunction.meta.state_off) then
                armed = false
            else
                armed = false
                local newMessage = { value = tonumber(controlFunction.meta.state_off), timestamp = edge:time() }
                mq:pub(controlFunction.meta.topic_read, json:encode(newMessage))
            end
        end
    end

    triggerFunctions = findFunctions(cfg.trigger_functions)
    actuatorFunctions = findFunctions(cfg.actuator_functions)

    for _, fn in ipairs(triggerFunctions) do
        mq:sub(fn.meta.topic_read)
        mq:bind(fn.meta.topic_read, onTriggerMessage)
    end
end