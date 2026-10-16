-- CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
-- Tests du langage : wdluart tests/lang.lua   (ou Exécuter dans l'IDE)
local ok, fails = 0, 0
local function check(name, cond)
  if cond then ok += 1 else fails += 1 print("ÉCHEC : " .. name) end
end

-- nombres (Lua 5.4)
check("entier", math.type(3) == "integer")
check("flottant", math.type(3.0) == "float")
check("division", 7 / 2 == 3.5)
check("division entière", 7 // 2 == 3 and -7 // 2 == -4)
check("\\ du manuel", 7 \ 2 == 3)
check("modulo", -7 % 3 == 2 and 7 % -3 == -2)
check("puissance", 2 ^ 10 == 1024.0)
check("hexadécimal", 0xff == 255 and 0x1p4 == 16.0)
check("binaire 0b", 0b1010 == 10)
check("bits", (5 & 3) == 1 and (5 | 3) == 7 and (5 ~ 3) == 6 and (1 << 4) == 16 and ~0 == -1)
check("tostring flottant", tostring(1.0) == "1.0" and tostring(10 // 1) == "10")
check("coercition", "10" + 5 == 15 and 10 .. "" == "10")
check("maxinteger boucle", math.maxinteger + 1 == math.mininteger)

-- extensions du manuel (§9.2)
local a = 10
a += 5   check("+=", a == 15)
a -= 3   check("-=", a == 12)
a *= 2   check("*=", a == 24)
a //= 5  check("//=", a == 4)
local s = "ab"
s ..= "cd" check("..=", s == "abcd")
check("!=", 1 != 2 and not (1 != 1))
local x = 0
if (x == 0) x = 1
check("if court", x == 1)
if (x == 0) x = 5 else x = 7
check("if court else", x == 7)
local n = 0
while (n < 10) n += 1
check("while court", n == 10)

-- chaînes et motifs
check("sub", ("bonjour"):sub(2, 4) == "onj" and ("bonjour"):sub(-3) == "our")
check("format", string.format("%05.1f|%-3s|%x", 3.14159, "a", 255) == "003.1|a  |ff")
check("find", ("hello world"):find("wor") == 7)
check("match", ("clé=valeur"):match("^(.-)=(.*)$") == "clé")
check("gsub", ("a,b,,c"):gsub(",", ";") == "a;b;;c")
check("gsub fonction", ("x1 y2"):gsub("%d", function(d) return d * 2 end) == "x2 y4")
local mots = {}
for w in ("un deux trois"):gmatch("%a+") do mots[#mots + 1] = w end
check("gmatch", #mots == 3 and mots[3] == "trois")
check("%b", ("f(a(b)c)d"):match("%b()") == "(a(b)c)")
check("rep", ("ab"):rep(3, "-") == "ab-ab-ab")

-- tables
local t = {10, 20, 30, k = "v"}
check("longueur", #t == 3)
table.insert(t, 40) check("insert", t[4] == 40)
table.insert(t, 1, 5) check("insert pos", t[1] == 5 and t[5] == 40)
check("remove", table.remove(t) == 40 and #t == 4)
check("concat", table.concat({1, 2, 3}, ",") == "1,2,3")
local u = {5, 2, 8, 1}
table.sort(u) check("sort", u[1] == 1 and u[4] == 8)
table.sort(u, function(p, q) return p > q end) check("sort comp", u[1] == 8)
check("unpack", select("#", table.unpack({1, 2, 3})) == 3)
local cnt = 0
for k, v in pairs({a = 1, b = 2, 3}) do cnt += 1 end
check("pairs", cnt == 3)

-- fonctions du manuel (§10.5, §10.6)
local m = {}
add(m, "a") add(m, "b") add(m, "c", 1)
check("add", m[1] == "c" and #m == 3)
check("del", del(m, "a") == "a" and #m == 2)
check("deli", deli(m) == "b" and #m == 1)
check("count", count({1, 2, 1}, 1) == 2)
local sum = 0
for v in all({1, 2, 3}) do sum += v end
check("all", sum == 6)
local sp = split("1,2,trois")
check("split", sp[1] == 1 and sp[3] == "trois")
check("chr/ord", chr(65, 66) == "AB" and ord("A") == 65)
check("flr/mid", flr(2.7) == 2 and mid(1, 5, 3) == 3)

-- closures, varargs, récursion
local function compteur()
  local c = 0
  return function() c += 1 return c end
end
local c1, c2 = compteur(), compteur()
c1() c1()
check("closure", c1() == 3 and c2() == 1)
local fs = {}
for i = 1, 3 do fs[i] = function() return i end end
check("closure de boucle", fs[1]() == 1 and fs[3]() == 3)
local function va(...) return select("#", ...), ... end
local nb, premier = va(7, 8, 9)
check("varargs", nb == 3 and premier == 7)
local function fact(k) if k <= 1 then return 1 end return k * fact(k - 1) end
check("récursion", fact(10) == 3628800)

-- métatables
local V = {}
V.__index = V
V.__add = function(p, q) return setmetatable({x = p.x + q.x}, V) end
V.__eq = function(p, q) return p.x == q.x end
V.__tostring = function(p) return "V(" .. p.x .. ")" end
function V.new(x) return setmetatable({x = x}, V) end
function V:double() return V.new(self.x * 2) end
local v = V.new(2) + V.new(3)
check("__add", v.x == 5)
check("méthode", v:double().x == 10)
check("__eq", V.new(1) == V.new(1))
check("__tostring", tostring(v) == "V(5)")
local defaut = setmetatable({}, {__index = function(_, k) return k .. "!" end})
check("__index fonction", defaut.ok == "ok!")

-- erreurs
local okp, err = pcall(function() error("boum") end)
check("pcall", not okp and err:find("boum") ~= nil)
local okp2, err2 = pcall(function() return nil + 1 end)
check("erreur arithmétique", not okp2 and err2:find("arithmétique") ~= nil)
check("error table", select(2, pcall(error, {code = 42})).code == 42)

-- coroutines
local co = coroutine.create(function(p)
  local q = coroutine.yield(p + 1)
  return q * 2
end)
local r1, y1 = coroutine.resume(co, 1)
local r2, y2 = coroutine.resume(co, 10)
check("coroutine", r1 and y1 == 2 and r2 and y2 == 20 and coroutine.status(co) == "dead")
local gen = coroutine.wrap(function() for i = 1, 3 do coroutine.yield(i) end end)
check("wrap", gen() == 1 and gen() == 2 and gen() == 3)

-- goto refusé
check("goto refusé", load("goto fin") == nil)

print(string.format("%d tests réussis, %d échecs", ok, fails))
if fails > 0 then os.exit(1) end
