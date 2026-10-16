-- CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
-- Multitâche : tâches coopératives et threads système
local task   = require "task"
local thread = require "thread"

local ch = task.channel()
task.spawn(function()
  for i = 1, 5 do
    ch:send(i * i)
    task.sleep(0.1)
  end
  ch:send(nil)
end)
task.spawn(function()
  while true do
    local v = ch:receive()
    if v == nil then break end
    print("reçu", v)
  end
end)
task.run()

-- un vrai thread, avec son propre interpréteur
local th = thread.start([[
  local n = thread.receive()
  local s = 0
  for i = 1, n do s += i end
  thread.send({somme = s})
]])
th:send(1000000)
local r = th:receive()
print("somme calculée par le thread :", r.somme)
th:join()
