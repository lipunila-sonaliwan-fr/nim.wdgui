-- CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
-- Fichiers, CSV, JSON, SQLite et motifs Lua
local bin = require "bin"
local file   = require "file"
local csv    = require "csv"
local json   = require "json"
local sqlite = require "sqlite"

local dir = file.tmpdir()
local path = file.join(dir, "ventes.csv")
file.write(path, "region,mois,montant\nNord,1,1200\nSud,1,950\nNord,2,1430\n")

local rows = csv.read(path, {header = true})
local total = 0
for r in all(rows) do total += r.montant end           -- all() du manuel (§10.6)
print("lignes :", #rows, "total :", total)

print(json.encode(rows, true))

local db = assert(sqlite.open(":memory:"))
db:exec("create table ventes(region text, mois integer, montant real)")
db:transaction(function(db)
  for r in all(rows) do
    db:exec("insert into ventes values (?, ?, ?)", r.region, r.mois, r.montant)
  end
end)
for _, r in ipairs(db:query("select region, sum(montant) as s from ventes group by region order by s desc")) do
  print(string.format("%-6s %8.2f", r.region, r.s))
end
db:close()

-- motifs Lua
for mot, n in ("pommes=3, poires=12, kiwis=7"):gmatch("(%a+)=(%d+)") do
  print(mot, tonumber(n) * 2)
end

local entete = bin.pack("<I4 z d", 42, "wdlua", 3.5)
print("binaire :", bin.tohex(entete), bin.unpack("<I4 z d", entete))
