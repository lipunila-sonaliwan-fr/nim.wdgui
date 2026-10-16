-- CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
-- Carnet d'adresses : grille wdgui + base SQLite + menus
local ui     = require "ui"
local sqlite = require "sqlite"
local file   = require "file"

local db = assert(sqlite.open(file.join(file.home(), "carnet_wdlua.db")))
db:exec("create table if not exists contacts(id integer primary key, nom text, email text, age integer)")

local win = ui.window{title = "Carnet", width = 720, height = 460, layout = "border"}
local menu = win:add(ui.menubar())
menu.dock = "top"
menu:add("Fichier", "Ajouter un contact")
menu:add("Fichier", "Exporter en CSV…")
menu:add("Fichier", "Quitter")

local grid = win:add(ui.grid{multi = false})
grid.dock = "center"
grid:addcolumn{name = "id", title = "#", kind = "number", width = 50, decimals = 0}
grid:addcolumn{name = "nom", title = "Nom", width = 220}
grid:addcolumn{name = "email", title = "Courriel", width = 260}
grid:addcolumn{name = "age", title = "Âge", kind = "number", width = 70, decimals = 0}
grid:setfooter("age", "average")

local function recharger()
  grid:clear()
  for r in db:rows("select * from contacts order by nom") do
    grid:addline(r.id, r.nom, r.email or "", r.age or "")
  end
end

menu.onselection = function(ev)
  local choix = ev.path and ev.path[#ev.path] or ev.text
  if choix == "Ajouter un contact" then
    local nom = ui.prompt("Nom :", "")
    if nom ~= "" then
      db:exec("insert into contacts(nom, email, age) values (?, ?, ?)",
              nom, ui.prompt("Courriel :", ""), tonumber(ui.prompt("Âge :", "")) )
      recharger()
    end
  elseif choix == "Exporter en CSV…" then
    local p = ui.savefile{name = "contacts.csv", filter = "CSV|*.csv"}
    if p then grid:savecsv(p) end
  elseif choix == "Quitter" then
    win:close()
  end
end

recharger()
ui.run()
db:close()
