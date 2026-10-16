-- CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
-- Fenêtre, bouton, compteur : le minimum avec le paquet ui
local ui = require "ui"
-- ui.trace(true)   -- décommentez pour afficher chaque événement reçu dans la console

local win = ui.window{title = "Bonjour wdlua", width = 420, height = 200}
local lbl = win:add(ui.label("Cliquez sur le bouton", "center"))
local nb = 0
local btn = win:add(ui.button("Compter", {default = true}))

btn.onclick = function(ev)
  nb += 1                                  -- affectation composée (manuel §9.2)
  btn.value = "Clics : " .. nb
end

ui.run()
