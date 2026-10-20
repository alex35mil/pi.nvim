--- Pi's canonical queue and entries awaiting their delivery events.

---@class pi.BackendQueueEntry
---@field queue_type "steer"|"follow_up"
---@field text string Backend-expanded message text.

---@class pi.BackendQueue
---@field _pending pi.BackendQueueEntry[]
---@field _dequeued pi.BackendQueueEntry[]
local Queue = {}
Queue.__index = Queue

---@param entries pi.BackendQueueEntry[]
---@param text string
---@param queue_type? "steer"|"follow_up"
---@return pi.BackendQueueEntry?
local function take(entries, text, queue_type)
    for i, entry in ipairs(entries) do
        if entry.text == text and (not queue_type or entry.queue_type == queue_type) then
            return table.remove(entries, i)
        end
    end
    return nil
end

---@return pi.BackendQueue
function Queue.new()
    return setmetatable({ _pending = {}, _dequeued = {} }, Queue)
end

--- Replace only backend state; local submissions never enter this queue.
---@param steering string[]
---@param follow_up string[]
function Queue:update(steering, follow_up)
    local previous = self._pending
    local pending = {}

    ---@param queue_type "steer"|"follow_up"
    ---@param messages string[]
    local function append(queue_type, messages)
        for _, text in ipairs(messages) do
            pending[#pending + 1] = take(previous, text, queue_type) or { queue_type = queue_type, text = text }
        end
    end

    append("steer", steering)
    append("follow_up", follow_up)
    for _, entry in ipairs(previous) do
        self._dequeued[#self._dequeued + 1] = entry
    end
    self._pending = pending
end

--- Pi normally removes the entry before emitting its user message_start.
--- Prefer removed entries so identical messages still pending keep their mode.
---@param text string Backend text from the delivery event, not local input.
---@return pi.BackendQueueEntry?
function Queue:consume(text)
    return take(self._dequeued, text) or take(self._pending, text)
end

---@return pi.BackendQueueEntry[]
function Queue:pending()
    return { unpack(self._pending) }
end

--- End delivery bookkeeping without fabricating a new queue snapshot.
function Queue:settled()
    self._dequeued = {}
end

--- Clear state when the session or process is discarded.
function Queue:clear()
    self._pending = {}
    self._dequeued = {}
end

return Queue
