# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - multitâche
#
#   task    tâches coopératives (coroutines + ordonnanceur) dans le même
#           interpréteur : task.spawn, task.sleep, task.yield, task.run,
#           canaux task.channel() ; idéal pour les automates et les E/S.
#   thread  vrais threads système : chaque thread a son propre interpréteur
#           et communique par messages (valeurs converties en JSON).

import std/[tables, times, os, locks, deques, json, strutils, atomics]
import ../lua/api, ../lua/stdlib, pkg_data

#
# task
#

type
  Task* = ref object of LUser
    co: Coroutine
    wakeAt: float
    result: seq[Value]
    error: Value
    failed: bool

  LChannel* = ref object of LUser
    items: Deque[Value]
    capacity: int

  Scheduler = ref object of RootObj
    tasks: seq[Task]
    current: Task

var taskMethods {.threadvar.}: LTable
var chanMethods {.threadvar.}: LTable

proc sched(L: Interp): Scheduler =
  let r = L.ext.getOrDefault("task")
  if r.isNil:
    result = Scheduler()
    L.ext["task"] = result
  else:
    result = Scheduler(r)

proc inTask(L: Interp): Task =
  let co = ctx().co
  if co.isNil: return nil
  for t in L.sched.tasks:
    if t.co == co: return t
  nil

proc waitUntil(L: Interp, cond: proc (): bool) =
  # Dans une tâche : rend la main jusqu'à ce que cond() soit vraie.
  # Hors tâche : fait tourner les autres tâches en attendant.
  let t = L.inTask()
  if not t.isNil:
    while not cond():
      discard L.yieldCo(@[])
    return
  while not cond():
    var progressed = false
    for tk in L.sched.tasks:
      if tk.co.status == csSuspended and epochTime() >= tk.wakeAt:
        progressed = true
        L.sched.current = tk
        let (ok, vals) = L.resume(tk.co, @[])
        L.sched.current = nil
        if not ok:
          tk.failed = true
          tk.error = first(vals)
          L.onError("tâche : " & L.tostr(tk.error))
        elif tk.co.status == csDead:
          tk.result = vals
    if not progressed:
      L.blocking: sleep(5)
    L.checkStop()

proc runAll(L: Interp) =
  L.waitUntil(proc (): bool =
    for t in L.sched.tasks:
      if t.co.status != csDead: return false
    true)

proc openTask(L: Interp): Value =
  taskMethods = newLib()
  chanMethods = newLib()
  taskMethods.fn "status", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = checkUser[Task](L, a, 1, "status", "tâche")
    @[strV(if t.failed: "error" else: $t.co.status)]
  taskMethods.fn "wait", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = checkUser[Task](L, a, 1, "wait", "tâche")
    L.waitUntil(proc (): bool = t.co.status == csDead)
    if t.failed: raiseValue(t.error)
    t.result
  taskMethods.fn "cancel", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = checkUser[Task](L, a, 1, "cancel", "tâche")
    if t.co.status == csSuspended: closeCoroutine(t.co)
  chanMethods.fn "send", proc (L: Interp, a: seq[Value]): seq[Value] =
    let c = checkUser[LChannel](L, a, 1, "send", "canal")
    L.waitUntil(proc (): bool = c.capacity <= 0 or c.items.len < c.capacity)
    c.items.addLast arg(a, 2)
  chanMethods.fn "receive", proc (L: Interp, a: seq[Value]): seq[Value] =
    let c = checkUser[LChannel](L, a, 1, "receive", "canal")
    let timeout = L.optNum(a, 2, "receive", -1)
    let deadline = if timeout >= 0: epochTime() + timeout else: Inf
    L.waitUntil(proc (): bool = c.items.len > 0 or epochTime() >= deadline)
    if c.items.len == 0: return @[nilV, strV("timeout")]
    @[c.items.popFirst()]
  chanMethods.fn "count", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[intV(checkUser[LChannel](L, a, 1, "count", "canal").items.len)]

  let m = newLib()
  m.fn "spawn", proc (L: Interp, a: seq[Value]): seq[Value] =
    let f = L.checkFunc(a, 1, "spawn")
    let args = if a.len > 1: a[1 .. ^1] else: @[]
    let body = fnV("task", proc (L: Interp, x: seq[Value]): seq[Value] = L.call(f, args))
    let t = Task(co: L.newCoroutine(body))
    L.sched.tasks.add t
    @[L.wrap(t, "task", taskMethods)]
  m.fn "sleep", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.optNum(a, 1, "sleep", 0)
    let t = L.inTask()
    if t.isNil:
      let until = epochTime() + s
      L.waitUntil(proc (): bool = epochTime() >= until)
    else:
      t.wakeAt = epochTime() + s
      discard L.yieldCo(@[])
  m.fn "yield", proc (L: Interp, a: seq[Value]): seq[Value] =
    if not L.inTask().isNil: discard L.yieldCo(@[])
  m.fn "run", proc (L: Interp, a: seq[Value]): seq[Value] =
    L.runAll()
  m.fn "channel", proc (L: Interp, a: seq[Value]): seq[Value] =
    let c = LChannel(capacity: int(L.optInt(a, 1, "channel", 0)), items: initDeque[Value]())
    @[L.wrap(c, "channel", chanMethods)]
  m.fn "now", proc (L: Interp, a: seq[Value]): seq[Value] = @[numV(epochTime())]
  m.fn "count", proc (L: Interp, a: seq[Value]): seq[Value] =
    var n = 0
    for t in L.sched.tasks:
      if t.co.status != csDead: inc n
    @[intV(n)]
  tableV(m)

registerPackage PackageDef(name: "task", open: openTask,
  description: "Tâches coopératives",
  docs: docs("task", [
    "task.spawn(f, ...)", "Crée une tâche qui exécutera f(...) ; elle démarre au prochain task.run(), task.sleep() ou attente.",
    "task.run()", "Fait tourner les tâches jusqu'à ce qu'elles soient toutes terminées.",
    "task.sleep(seconds)", "Dans une tâche : la suspend ; ailleurs : attend en faisant tourner les tâches.",
    "task.yield()", "Rend la main aux autres tâches.",
    "task.channel([capacity])", "Canal de communication (capacité 0 = illimitée).",
    "task.count()", "Nombre de tâches en cours.",
    "task.now()", "Heure en secondes (avec décimales).",
    "t:wait()", "Attend la fin d'une tâche et renvoie ses résultats.",
    "t:status()", "\"suspended\", \"running\", \"dead\" ou \"error\".",
    "t:cancel()", "Arrête une tâche suspendue.",
    "ch:send(value)", "Envoie une valeur (attend s'il est plein).",
    "ch:receive([timeout])", "Reçoit une valeur (attend si vide) ; nil, \"timeout\" après le délai.",
    "ch:count()", "Nombre de valeurs en attente."]))

#
# thread
#

type
  MsgQueue = ref object
    lock: Lock
    cond: Cond
    items: Deque[string]

  ThreadData = object
    code, path: string
    args: seq[string]
    toChild, toParent: MsgQueue
    output, errput: proc (s: string) {.closure.}
    stop: ptr Atomic[bool]
    done: ptr Atomic[bool]
    error: ptr string

  LThread* = ref object of LUser
    thr: ptr Thread[ThreadData]
    toChild, toParent: MsgQueue
    stop: ptr Atomic[bool]
    done: ptr Atomic[bool]
    error: ptr string
    joined: bool

  ChildLink = ref object of RootObj
    toChild, toParent: MsgQueue

var threadMethods {.threadvar.}: LTable

proc newQueue(): MsgQueue =
  result = MsgQueue(items: initDeque[string]())
  initLock(result.lock)
  initCond(result.cond)

proc push(q: MsgQueue, s: string) =
  withLock q.lock:
    q.items.addLast s
    signal(q.cond)

proc pop(L: Interp, q: MsgQueue, timeout: float): (bool, string) =
  let deadline = if timeout >= 0: epochTime() + timeout else: Inf
  L.blocking:
    while true:
      acquire(q.lock)
      if q.items.len > 0:
        let s = q.items.popFirst()
        release(q.lock)
        return (true, s)
      release(q.lock)
      if epochTime() >= deadline or L.stopRequested(): break
      sleep(5)
  (false, "")

proc encodeMsg(L: Interp, v: Value): string = $L.toJsonNode(v)
proc decodeMsg(L: Interp, s: string): Value = L.fromJsonNode(parseJson(s), nullAsNil = true)

proc threadMain(d: ThreadData) {.thread.} =
  {.cast(gcsafe).}:
    let L = newFullInterp()
    L.output = d.output
    L.errput = d.errput
    L.args = d.args
    L.scriptPath = d.path
    L.ext["thread.link"] = ChildLink(toChild: d.toChild, toParent: d.toParent)
    L.parentStop = d.stop          # th:stop() et l'arrêt du parent se propagent
    L.enter()
    try:
      let src = if d.path.len > 0: readFile(d.path) else: d.code
      var args: seq[Value]
      for s in d.args: args.add strV(s)
      discard L.call(L.load(src, (if d.path.len > 0: d.path else: "thread")), args)
    except LuaError as e:
      d.error[] = e.msg
    except LuaStop:
      discard
    except CatchableError as e:
      d.error[] = e.msg
    L.shutdown()
    L.leave()
    d.done[].store(true)

proc checkThread(L: Interp, a: seq[Value], fname: string): LThread =
  checkUser[LThread](L, a, 1, fname, "thread")

proc joinThreadObj(t: LThread) =
  if not t.joined:
    joinThread(t.thr[])
    deallocShared(t.thr)
    t.joined = true

proc openThread(L: Interp): Value =
  threadMethods = newLib()
  let tm = threadMethods
  tm.fn "send", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = L.checkThread(a, "send")
    t.toChild.push(L.encodeMsg(arg(a, 2)))
  tm.fn "receive", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = L.checkThread(a, "receive")
    let (ok, s) = L.pop(t.toParent, L.optNum(a, 2, "receive", -1))
    if not ok: return @[nilV, strV("timeout")]
    @[L.decodeMsg(s)]
  tm.fn "alive", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[boolV(not L.checkThread(a, "alive").done[].load())]
  tm.fn "join", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = L.checkThread(a, "join")
    L.blocking:
      while not t.done[].load(): sleep(5)
    t.joinThreadObj()
    if t.error[].len > 0: return @[boolV(false), strV(t.error[])]
    @[boolV(true)]
  tm.fn "stop", proc (L: Interp, a: seq[Value]): seq[Value] =
    L.checkThread(a, "stop").stop[].store(true)

  let m = newLib()
  proc startThread(L: Interp, code, path: string, args: seq[string]): Value =
    let t = LThread(toChild: newQueue(), toParent: newQueue())
    t.stop = createShared(Atomic[bool])
    t.done = createShared(Atomic[bool])
    t.error = createShared(string)
    t.thr = createShared(Thread[ThreadData])
    let d = ThreadData(code: code, path: path, args: args, toChild: t.toChild, toParent: t.toParent,
                       output: L.output, errput: L.errput, stop: t.stop, done: t.done, error: t.error)
    createThread(t.thr[], threadMain, d)
    L.closers.add proc () =
      t.stop[].store(true)
      t.joinThreadObj()
    L.wrap(t, "thread", threadMethods)
  m.fn "start", proc (L: Interp, a: seq[Value]): seq[Value] =
    let src = L.checkStr(a, 1, "start")
    var args: seq[string]
    for i in 2 .. a.len: args.add L.tostr(a[i - 1])
    if src.endsWith(".lua") and '\n' notin src:
      let p = if isAbsolute(src) or L.scriptPath.len == 0: src else: L.scriptPath.parentDir / src
      return @[startThread(L, "", p, args)]
    @[startThread(L, src, "", args)]
  # côté enfant : communication avec le parent
  m.fn "send", proc (L: Interp, a: seq[Value]): seq[Value] =
    let link = L.ext.getOrDefault("thread.link")
    if link.isNil: rtError("thread.send : à utiliser dans un thread (sinon t:send)")
    ChildLink(link).toParent.push(L.encodeMsg(arg(a, 1)))
  m.fn "receive", proc (L: Interp, a: seq[Value]): seq[Value] =
    let link = L.ext.getOrDefault("thread.link")
    if link.isNil: rtError("thread.receive : à utiliser dans un thread (sinon t:receive)")
    let (ok, s) = L.pop(ChildLink(link).toChild, L.optNum(a, 1, "receive", -1))
    if not ok: return @[nilV, strV("timeout")]
    @[L.decodeMsg(s)]
  m.fn "ischild", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[boolV(not L.ext.getOrDefault("thread.link").isNil)]
  tableV(m)

registerPackage PackageDef(name: "thread", open: openThread,
  description: "Threads système (interpréteurs séparés, messages)",
  docs: docs("thread", [
    "thread.start(code_or_file, ...)", "Lance un thread qui exécute du code Lua (chaîne) ou un fichier .lua, avec ses propres variables.",
    "thread.send(value)", "Dans le thread : envoie une valeur au parent.",
    "thread.receive([timeout])", "Dans le thread : reçoit une valeur du parent.",
    "thread.ischild()", "Vrai dans un thread lancé par thread.start.",
    "th:send(value)", "Envoie une valeur au thread (tables, chaînes, nombres, booléens).",
    "th:receive([timeout])", "Reçoit une valeur du thread ; nil, \"timeout\" après le délai.",
    "th:alive()", "Vrai tant que le thread s'exécute.",
    "th:join()", "Attend la fin : true, ou false et le message d'erreur.",
    "th:stop()", "Demande l'arrêt du thread."]))
