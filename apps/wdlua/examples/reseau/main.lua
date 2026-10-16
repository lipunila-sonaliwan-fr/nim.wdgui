-- CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
-- HTTP, TCP local et SSH (si configuré)
local http = require "http"
local net  = require "net"

local body, status = http.get("https://example.com")
if body then
  print("HTTP", status, #body .. " octets", body:match("<title>(.-)</title>"))
else
  print("HTTP indisponible :", status)
end

-- petit serveur TCP local dans une tâche, et un client
local task = require "task"
local srv = assert(net.listen(5577, "127.0.0.1"))
task.spawn(function()
  local c = srv:accept()
  local line = c:receive("l")
  c:send("écho : " .. line .. "\n")
  c:close()
end)
task.spawn(function()
  local c = assert(net.connect("127.0.0.1", 5577))
  c:send("bonjour\n")
  print(c:receive("l"))
  c:close()
end)
task.run()
srv:close()

-- SSH : décommentez et adaptez (authentification par clé)
-- local ssh = require "ssh"
-- local s = assert(ssh.connect{host = "serveur", user = "moi", key = "~/.ssh/id_ed25519"})
-- print(s:exec("uname -a"))
-- s:put("local.txt", "/tmp/distant.txt")
