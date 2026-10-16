-- main.lua : point d'entrée du projet
new = function (_,o)
  o = o or {}
  _.__index=_
  return setmetatable(o,_)
end

local personne = {
  nom = "anonyme",
  presenter = function (_)
    print("Bonjour, je suis " .. _.nom .. ".")
  end
}

local moi, lui = new(personne), new(personne, { nom = "Un autre" })
moi:presenter()
lui:presenter()

