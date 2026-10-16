# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - paquets réseau
#
#   net    sockets TCP (avec TLS) et UDP, résolution DNS
#   http   client HTTP/HTTPS (std/httpclient ; HTTPS demande -d:ssl et OpenSSL)
#   ftp    client FTP (mode passif) écrit sur les sockets de `net`
#   ssh    exécution distante, et sftp : transferts de fichiers, via le client
#          OpenSSH installé (ssh, scp, sftp), authentification par clé ;
#          mot de passe possible si `sshpass` est installé.
#
# Les opérations bloquantes libèrent l'interpréteur : les fenêtres et les
# gestionnaires d'événements restent réactifs pendant un transfert.

import std/[net, httpclient, strutils, os, osproc, tables, uri, nativesockets, streams, strtabs]
import ../lua/api

#
# net
#

type
  LSocket* = ref object of LUser
    sock*: Socket
    closed*: bool
    timeout*: int          # ms, -1 = aucun
    udp*: bool

var sockMethods {.threadvar.}: LTable

proc checkSock(L: Interp, a: seq[Value], fname: string): LSocket =
  result = checkUser[LSocket](L, a, 1, fname, "socket")
  if result.closed: rtError("socket fermé")

proc wrapSock(L: Interp, s: LSocket): Value =
  L.closers.add proc () =
    if not s.closed:
      s.closed = true
      try: s.sock.close() except CatchableError: discard
  L.wrap(s, "socket", sockMethods)

when defined(ssl):
  var sslCtx {.threadvar.}: SslContext
  proc tlsContext(): SslContext =
    if sslCtx.isNil: sslCtx = newContext(verifyMode = CVerifyPeer)
    sslCtx

proc tcpConnect*(L: Interp, host: string, port: int, tls: bool, timeout: int): Socket =
  result = newSocket()
  try:
    L.blocking:
      if timeout > 0: result.connect(host, Port(port), timeout)
      else: result.connect(host, Port(port))
    if tls:
      when defined(ssl):
        tlsContext().wrapConnectedSocket(result, handshakeAsClient, host)
      else:
        rtError("TLS indisponible : compilez avec -d:ssl")
  except OSError, TimeoutError:
    result.close()
    raise

proc recvLine(L: Interp, s: LSocket): (bool, string) =
  var line = ""
  L.blocking:
    if s.timeout > 0: s.sock.readLine(line, s.timeout)
    else: s.sock.readLine(line)
  if line.len == 0: return (false, "")       # connexion fermée
  if line == "\r\n": return (true, "")
  (true, line)

proc openNet(L: Interp): Value =
  sockMethods = newLib()
  let sm = sockMethods
  sm.fn "send", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkSock(a, "send")
    let data = L.checkStr(a, 2, "send")
    try:
      L.blocking: s.sock.send(data)
      @[intV(data.len)]
    except OSError as e: fail(e.msg)
  sm.fn "receive", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkSock(a, "receive")
    let what = arg(a, 2)
    try:
      if what.kind in {vkInt, vkNum}:
        var ok: bool
        let n = int(toInteger(what, ok))
        var data = ""
        L.blocking:
          discard s.sock.recv(data, n, (if s.timeout > 0: s.timeout else: -1))
        if data.len == 0: return fail("closed")
        return @[strV(data)]
      let mode = if what.kind == vkStr: what.s.strip(chars = {'*'}) else: "l"
      if mode == "a":
        var all = ""
        L.blocking:
          while true:
            let chunk = s.sock.recv(4096, (if s.timeout > 0: s.timeout else: -1))
            if chunk.len == 0: break
            all.add chunk
        return @[strV(all)]
      let (ok, line) = L.recvLine(s)
      if not ok: return fail("closed")
      @[strV(line)]
    except TimeoutError: fail("timeout")
    except OSError as e: fail(e.msg)
  sm.fn "settimeout", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkSock(a, "settimeout")
    let v = arg(a, 2)
    s.timeout = if v.kind == vkNil: -1 else: int(L.checkNum(a, 2, "settimeout") * 1000)
  sm.fn "accept", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkSock(a, "accept")
    var client: Socket
    new(client)
    var address = ""
    try:
      L.blocking: s.sock.acceptAddr(client, address)
    except OSError as e: return fail(e.msg)
    @[L.wrapSock(LSocket(sock: client, timeout: -1)), strV(address)]
  sm.fn "sendto", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkSock(a, "sendto")
    try:
      s.sock.sendTo(L.checkStr(a, 4, "sendto"), Port(L.checkInt(a, 3, "sendto")), L.checkStr(a, 2, "sendto"))
      @[boolV(true)]
    except OSError as e: fail(e.msg)
  sm.fn "receivefrom", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkSock(a, "receivefrom")
    let size = int(L.optInt(a, 2, "receivefrom", 8192))
    var data = ""
    var address = ""
    var port: Port
    try:
      L.blocking: discard s.sock.recvFrom(data, size, address, port)
    except OSError as e: return fail(e.msg)
    @[strV(data), strV(address), intV(int(port))]
  sm.fn "peer", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkSock(a, "peer")
    try:
      let (address, port) = s.sock.getPeerAddr()
      @[strV(address), intV(int(port))]
    except OSError as e: fail(e.msg)
  sm.fn "close", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = checkUser[LSocket](L, a, 1, "close", "socket")
    if not s.closed:
      s.closed = true
      s.sock.close()
    @[boolV(true)]

  let m = newLib()
  m.fn "connect", proc (L: Interp, a: seq[Value]): seq[Value] =
    let host = L.checkStr(a, 1, "connect")
    let port = int(L.checkInt(a, 2, "connect"))
    let opts = if arg(a, 3).kind == vkTable: a[2].t else: nil
    try:
      let sock = L.tcpConnect(host, port, optField(opts, "tls", false),
                              int(optField(opts, "timeout", 0.0) * 1000))
      @[L.wrapSock(LSocket(sock: sock, timeout: int(optField(opts, "timeout", -0.001) * 1000)))]
    except OSError, TimeoutError: fail(host & ":" & $port & " : " & getCurrentExceptionMsg())
  m.fn "listen", proc (L: Interp, a: seq[Value]): seq[Value] =
    let port = int(L.checkInt(a, 1, "listen"))
    let host = L.optStr(a, 2, "listen", "0.0.0.0")
    try:
      let s = newSocket()
      s.setSockOpt(OptReuseAddr, true)
      s.bindAddr(Port(port), host)
      s.listen()
      @[L.wrapSock(LSocket(sock: s, timeout: -1))]
    except OSError as e: fail(e.msg)
  m.fn "udp", proc (L: Interp, a: seq[Value]): seq[Value] =
    try:
      let s = newSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
      if arg(a, 1).kind != vkNil:
        s.bindAddr(Port(L.checkInt(a, 1, "udp")), L.optStr(a, 2, "udp", "0.0.0.0"))
      @[L.wrapSock(LSocket(sock: s, timeout: -1, udp: true))]
    except OSError as e: fail(e.msg)
  m.fn "resolve", proc (L: Interp, a: seq[Value]): seq[Value] =
    let host = L.checkStr(a, 1, "resolve")
    try:
      var ip = ""
      L.blocking: ip = getHostByName(host).addrList[0]
      @[strV(ip)]
    except OSError, IndexDefect: fail(host & " : nom introuvable")
  m.fn "hostname", proc (L: Interp, a: seq[Value]): seq[Value] = @[strV(getHostname())]
  tableV(m)

registerPackage PackageDef(name: "net", open: openNet,
  description: "Sockets TCP/UDP",
  docs: docs("net", [
    "net.connect(host, port, [opts])", "Connexion TCP. opts : tls (true pour TLS, -d:ssl), timeout (secondes).",
    "net.listen(port, [host])", "Socket serveur TCP.",
    "net.udp([port], [host])", "Socket UDP, éventuellement lié à un port.",
    "net.resolve(host)", "Adresse IP d'un nom.",
    "net.hostname()", "Nom de la machine.",
    "sock:send(data)", "Envoie des octets ; renvoie le nombre envoyé.",
    "sock:receive([pattern])", "Reçoit : \"l\" une ligne (défaut), \"a\" jusqu'à la fermeture, ou un nombre d'octets.",
    "sock:settimeout(seconds)", "Délai des réceptions (nil = aucun).",
    "sock:accept()", "Attend un client (socket serveur) ; renvoie le socket et l'adresse.",
    "sock:sendto(data, port, host)", "Envoi UDP.",
    "sock:receivefrom([size])", "Réception UDP : données, adresse, port.",
    "sock:peer()", "Adresse et port distants.",
    "sock:close()", "Ferme le socket."]))

#
# http
#

proc httpRequest(L: Interp, meth, url, body: string, headers: LTable, timeout: int,
                 saveTo = ""): seq[Value] =
  var client: HttpClient
  try:
    when defined(ssl):
      client = newHttpClient(timeout = timeout, sslContext = newContext(verifyMode = CVerifyPeer))
    else:
      if url.toLowerAscii.startsWith("https"):
        return fail("HTTPS indisponible : compilez avec -d:ssl")
      client = newHttpClient(timeout = timeout)
    var hdrs = newHttpHeaders()
    if not headers.isNil:
      for k, v in headers.pairs:
        if k.kind == vkStr: hdrs[k.s] = L.tostr(v)
    client.headers = hdrs
    var resp: Response
    L.blocking:
      resp = client.request(url, httpMethod = meth.toUpperAscii, body = body)
    let respBody = resp.body
    if saveTo.len > 0:
      writeFile(saveTo, respBody)
    let t = newLTable()
    t.set "status", intV(resp.code.int)
    t.set "reason", strV(resp.status)
    t.set "body", strV(if saveTo.len > 0: "" else: respBody)
    let h = newLTable()
    for k, v in resp.headers.pairs: h.set k.toLowerAscii, strV(v)
    t.set "headers", tableV(h)
    @[tableV(t)]
  except CatchableError as e:
    if e of LuaError or e of LuaStop: raise e
    fail(url & " : " & e.msg)
  finally:
    if not client.isNil: client.close()

proc openHttp(L: Interp): Value =
  let m = newLib()
  m.fn "get", proc (L: Interp, a: seq[Value]): seq[Value] =
    let r = L.httpRequest("GET", L.checkStr(a, 1, "get"), "",
                          (if arg(a, 2).kind == vkTable: a[1].t else: nil), -1)
    if r[0].kind == vkNil: return r
    let t = r[0].t
    @[t.get("body"), t.get("status"), t.get("headers")]
  m.fn "post", proc (L: Interp, a: seq[Value]): seq[Value] =
    let r = L.httpRequest("POST", L.checkStr(a, 1, "post"), L.optStr(a, 2, "post", ""),
                          (if arg(a, 3).kind == vkTable: a[2].t else: nil), -1)
    if r[0].kind == vkNil: return r
    let t = r[0].t
    @[t.get("body"), t.get("status"), t.get("headers")]
  m.fn "request", proc (L: Interp, a: seq[Value]): seq[Value] =
    let o = L.checkTable(a, 1, "request")
    let hv = o.rawGet("headers")
    L.httpRequest(optField(o, "method", "GET"), optField(o, "url", ""), optField(o, "body", ""),
                  (if hv.kind == vkTable: hv.t else: nil), int(optField(o, "timeout", -0.001) * 1000))
  m.fn "download", proc (L: Interp, a: seq[Value]): seq[Value] =
    let r = L.httpRequest("GET", L.checkStr(a, 1, "download"), "", nil, -1, L.checkStr(a, 2, "download"))
    if r[0].kind == vkNil: return r
    @[boolV(true), r[0].t.get("status")]
  m.fn "urlencode", proc (L: Interp, a: seq[Value]): seq[Value] =
    let v = arg(a, 1)
    if v.kind == vkTable:
      var parts: seq[string]
      for k, x in v.t.pairs: parts.add encodeUrl(rawToString(k)) & "=" & encodeUrl(L.tostr(x))
      return @[strV(parts.join("&"))]
    @[strV(encodeUrl(L.checkStr(a, 1, "urlencode")))]
  m.fn "urldecode", proc (L: Interp, a: seq[Value]): seq[Value] = @[strV(decodeUrl(L.checkStr(a, 1, "urldecode")))]
  tableV(m)

registerPackage PackageDef(name: "http", open: openHttp,
  description: "Client HTTP/HTTPS",
  docs: docs("http", [
    "http.get(url, [headers])", "Requête GET : corps, statut, en-têtes ; nil et message en cas d'échec.",
    "http.post(url, body, [headers])", "Requête POST : corps, statut, en-têtes.",
    "http.request{method=, url=, headers=, body=, timeout=}", "Requête quelconque ; renvoie {status, reason, body, headers}.",
    "http.download(url, path)", "Télécharge dans un fichier.",
    "http.urlencode(s | table)", "Encodage d'URL (une table devient a=1&b=2).",
    "http.urldecode(s)", "Décodage d'URL."]))

#
# ftp (RFC 959, mode passif)
#

type
  FtpConn* = ref object of LUser
    ctrl: Socket
    closed: bool
    host: string

var ftpMethods {.threadvar.}: LTable

proc ftpReply(L: Interp, c: FtpConn): (int, string) =
  var all = ""
  var line = ""
  L.blocking:
    c.ctrl.readLine(line, 30_000)
    all = line
    if line.len >= 4 and line[3] == '-':
      let code = line[0 .. 2]
      while true:
        c.ctrl.readLine(line, 30_000)
        all.add "\n" & line
        if line.len >= 4 and line.startsWith(code) and line[3] == ' ': break
        if line.len == 0: break
  if all.len < 3: rtError("ftp : réponse invalide du serveur")
  var code = 0
  try: code = parseInt(all[0 .. 2])
  except ValueError: rtError("ftp : réponse invalide « " & all & " »")
  (code, all)

proc ftpCmd(L: Interp, c: FtpConn, cmd: string, expect: set[char] = {'2'}): (int, string) =
  L.blocking: c.ctrl.send(cmd & "\r\n")
  result = L.ftpReply(c)
  if result[1][0] notin expect:
    let shown = if cmd.startsWith("PASS"): "PASS ****" else: cmd
    rtError("ftp : " & shown & " → " & result[1])

proc ftpData(L: Interp, c: FtpConn): Socket =
  let (_, msg) = L.ftpCmd(c, "PASV")
  let a = msg.find('(')
  let b = msg.find(')', a + 1)
  if a < 0 or b < 0: rtError("ftp : réponse PASV invalide")
  let parts = msg[a + 1 ..< b].split(',')
  if parts.len != 6: rtError("ftp : réponse PASV invalide")
  let port = parseInt(parts[4].strip()) * 256 + parseInt(parts[5].strip())
  L.tcpConnect(c.host, port, false, 30_000)

proc ftpTransfer(L: Interp, c: FtpConn, cmd: string, upload = "", isUpload = false): string =
  discard L.ftpCmd(c, "TYPE I")
  let data = L.ftpData(c)
  discard L.ftpCmd(c, cmd, {'1', '2'})
  try:
    L.blocking:
      if isUpload:
        data.send(upload)
      else:
        while true:
          let chunk = data.recv(65536, 60_000)
          if chunk.len == 0: break
          result.add chunk
  finally:
    data.close()
  discard L.ftpReply(c)

proc checkFtp(L: Interp, a: seq[Value], fname: string): FtpConn =
  result = checkUser[FtpConn](L, a, 1, fname, "connexion ftp")
  if result.closed: rtError("connexion ftp fermée")

proc openFtp(L: Interp): Value =
  ftpMethods = newLib()
  let fm = ftpMethods
  fm.fn "list", proc (L: Interp, a: seq[Value]): seq[Value] =
    let c = L.checkFtp(a, "list")
    let path = L.optStr(a, 2, "list", "")
    let txt = L.ftpTransfer(c, (if optBool(a, 3, false): "LIST " else: "NLST ") & path)
    let t = newLTable()
    for l in txt.splitLines():
      if l.strip().len > 0: t.arr.add strV(l)
    @[tableV(t)]
  fm.fn "get", proc (L: Interp, a: seq[Value]): seq[Value] =
    let c = L.checkFtp(a, "get")
    let data = L.ftpTransfer(c, "RETR " & L.checkStr(a, 2, "get"))
    if arg(a, 3).kind != vkNil:
      writeFile(L.checkStr(a, 3, "get"), data)
      return @[boolV(true)]
    @[strV(data)]
  fm.fn "put", proc (L: Interp, a: seq[Value]): seq[Value] =
    let c = L.checkFtp(a, "put")
    let src = L.checkStr(a, 2, "put")
    let remote = L.optStr(a, 3, "put", extractFilename(src))
    let content = if fileExists(src) and arg(a, 4).kind == vkNil: readFile(src) else: src
    discard L.ftpTransfer(c, "STOR " & remote, content, true)
    @[boolV(true)]
  fm.fn "cd", proc (L: Interp, a: seq[Value]): seq[Value] =
    discard L.ftpCmd(L.checkFtp(a, "cd"), "CWD " & L.checkStr(a, 2, "cd"))
    @[boolV(true)]
  fm.fn "pwd", proc (L: Interp, a: seq[Value]): seq[Value] =
    let (_, msg) = L.ftpCmd(L.checkFtp(a, "pwd"), "PWD")
    let q1 = msg.find('"')
    let q2 = msg.find('"', q1 + 1)
    @[strV(if q1 >= 0 and q2 > q1: msg[q1 + 1 ..< q2] else: msg)]
  fm.fn "mkdir", proc (L: Interp, a: seq[Value]): seq[Value] =
    discard L.ftpCmd(L.checkFtp(a, "mkdir"), "MKD " & L.checkStr(a, 2, "mkdir"))
    @[boolV(true)]
  fm.fn "delete", proc (L: Interp, a: seq[Value]): seq[Value] =
    discard L.ftpCmd(L.checkFtp(a, "delete"), "DELE " & L.checkStr(a, 2, "delete"))
    @[boolV(true)]
  fm.fn "rmdir", proc (L: Interp, a: seq[Value]): seq[Value] =
    discard L.ftpCmd(L.checkFtp(a, "rmdir"), "RMD " & L.checkStr(a, 2, "rmdir"))
    @[boolV(true)]
  fm.fn "rename", proc (L: Interp, a: seq[Value]): seq[Value] =
    let c = L.checkFtp(a, "rename")
    discard L.ftpCmd(c, "RNFR " & L.checkStr(a, 2, "rename"), {'3'})
    discard L.ftpCmd(c, "RNTO " & L.checkStr(a, 3, "rename"))
    @[boolV(true)]
  fm.fn "close", proc (L: Interp, a: seq[Value]): seq[Value] =
    let c = checkUser[FtpConn](L, a, 1, "close", "connexion ftp")
    if not c.closed:
      try: discard L.ftpCmd(c, "QUIT")
      except LuaError: discard
      c.ctrl.close()
      c.closed = true
    @[boolV(true)]

  let m = newLib()
  m.fn "connect", proc (L: Interp, a: seq[Value]): seq[Value] =
    let o = L.checkTable(a, 1, "connect")
    let host = optField(o, "host", "")
    let port = optField(o, "port", 21)
    var c: FtpConn
    try:
      c = FtpConn(ctrl: L.tcpConnect(host, port, false, 30_000), host: host)
    except OSError, TimeoutError: return fail(host & " : " & getCurrentExceptionMsg())
    discard L.ftpReply(c)
    let (code, _) = L.ftpCmd(c, "USER " & optField(o, "user", "anonymous"), {'2', '3'})
    if code == 331: discard L.ftpCmd(c, "PASS " & optField(o, "password", ""))
    L.closers.add proc () =
      if not c.closed:
        c.closed = true
        try: c.ctrl.close() except CatchableError: discard
    @[L.wrap(c, "ftp", ftpMethods)]
  tableV(m)

registerPackage PackageDef(name: "ftp", open: openFtp,
  description: "Client FTP",
  docs: docs("ftp", [
    "ftp.connect{host=, port=21, user=\"anonymous\", password=\"\"}", "Ouvre une session FTP (mode passif).",
    "conn:list([path], [long])", "Noms des fichiers (long = true : format détaillé LIST).",
    "conn:get(remote, [localpath])", "Télécharge : renvoie les données, ou les écrit dans localpath.",
    "conn:put(localpath_or_data, [remote], [isData])", "Envoie un fichier local (ou des données si isData).",
    "conn:cd(path)", "Change de dossier distant.", "conn:pwd()", "Dossier distant courant.",
    "conn:mkdir(path)", "Crée un dossier.", "conn:rmdir(path)", "Supprime un dossier.",
    "conn:delete(path)", "Supprime un fichier.", "conn:rename(old, new)", "Renomme.",
    "conn:close()", "Ferme la session."]))

#
# ssh / sftp (client OpenSSH)
#

type
  SshSession* = ref object of LUser
    host, user, key, password: string
    port: int
    extra: seq[string]

var sshMethods {.threadvar.}: LTable

proc target(s: SshSession): string =
  if s.user.len > 0: s.user & "@" & s.host else: s.host

proc baseOpts(s: SshSession, portFlag: string): seq[string] =
  result = @["-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=20"]
  if s.password.len == 0: result.add ["-o", "BatchMode=yes"]
  if s.port > 0: result.add [portFlag, $s.port]
  if s.key.len > 0: result.add ["-i", s.key]
  result.add s.extra

proc runTool(L: Interp, s: SshSession, tool: string, args: seq[string], input = ""): (string, int) =
  var exe = findExe(tool)
  if exe.len == 0: rtError(tool & " introuvable : installez le client OpenSSH")
  var fullArgs = args
  var env: StringTableRef = nil
  if s.password.len > 0:
    let sp = findExe("sshpass")
    if sp.len == 0: rtError("authentification par mot de passe : installez « sshpass », ou utilisez une clé (key=)")
    fullArgs = @["-e", exe] & args
    exe = sp
    env = newStringTable()
    for k, v in envPairs(): env[k] = v
    env["SSHPASS"] = s.password
  var output = ""
  var code = 0
  L.blocking:
    let p = startProcess(exe, args = fullArgs, env = env, options = {poStdErrToStdOut})
    if input.len > 0:
      p.inputStream.write(input)
    p.inputStream.close()
    output = p.outputStream.readAll()
    code = p.waitForExit()
    p.close()
  (output, code)

proc checkSsh(L: Interp, a: seq[Value], fname: string): SshSession =
  checkUser[SshSession](L, a, 1, fname, "session ssh")

proc sshFromOpts(o: LTable): SshSession =
  result = SshSession(host: optField(o, "host", ""), user: optField(o, "user", ""),
                      key: optField(o, "key", ""), password: optField(o, "password", ""),
                      port: optField(o, "port", 0))
  let ex = o.rawGet("options")
  if ex.kind == vkTable:
    for i in 1 .. ex.t.rawLen: result.extra.add rawToString(ex.t.rawGet(intV(i)))
  if result.host.len == 0: rtError("ssh : champ host manquant")

proc sftpBatch(L: Interp, s: SshSession, commands: string): (string, int) =
  L.runTool(s, "sftp", s.baseOpts("-P") & @["-b", "-", s.target], commands)

proc quoteRemote(p: string): string = "\"" & p.replace("\"", "\\\"") & "\""

proc openSsh(L: Interp): Value =
  sshMethods = newLib()
  let sm = sshMethods
  sm.fn "exec", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkSsh(a, "exec")
    let (outp, code) = L.runTool(s, "ssh", s.baseOpts("-p") & @[s.target, L.checkStr(a, 2, "exec")])
    @[strV(outp), intV(code)]
  sm.fn "get", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkSsh(a, "get")
    let remote = L.checkStr(a, 2, "get")
    let local = L.optStr(a, 3, "get", extractFilename(remote))
    let (outp, code) = L.runTool(s, "scp", s.baseOpts("-P") & @["-r", s.target & ":" & remote, local])
    if code != 0: return fail(outp.strip())
    @[boolV(true)]
  sm.fn "put", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkSsh(a, "put")
    let local = L.checkStr(a, 2, "put")
    let remote = L.optStr(a, 3, "put", extractFilename(local))
    let (outp, code) = L.runTool(s, "scp", s.baseOpts("-P") & @["-r", local, s.target & ":" & remote])
    if code != 0: return fail(outp.strip())
    @[boolV(true)]
  sm.fn "list", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkSsh(a, "list")
    let (outp, code) = L.sftpBatch(s, "ls -1 " & quoteRemote(L.optStr(a, 2, "list", ".")) & "\n")
    if code != 0: return fail(outp.strip())
    let t = newLTable()
    for l in outp.splitLines():
      let x = l.strip()
      if x.len > 0 and not x.startsWith("sftp>"): t.arr.add strV(x)
    @[tableV(t)]
  template sftpSimple(name, cmd: string, nargs: int) =
    sm.fn name, proc (L: Interp, a: seq[Value]): seq[Value] =
      let s = L.checkSsh(a, name)
      var line = cmd
      for i in 2 .. nargs + 1: line.add " " & quoteRemote(L.checkStr(a, i, name))
      let (outp, code) = L.sftpBatch(s, line & "\n")
      if code != 0: return fail(outp.strip())
      @[boolV(true)]
  sftpSimple("mkdir", "mkdir", 1)
  sftpSimple("rmdir", "rmdir", 1)
  sftpSimple("remove", "rm", 1)
  sftpSimple("rename", "rename", 2)

  let m = newLib()
  m.fn "connect", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = sshFromOpts(L.checkTable(a, 1, "connect"))
    if optBool(a, 2, true):
      let (outp, code) = L.runTool(s, "ssh", s.baseOpts("-p") & @[s.target, "exit"])
      if code != 0: return fail(outp.strip())
    @[L.wrap(s, "ssh", sshMethods)]
  m.fn "exec", proc (L: Interp, a: seq[Value]): seq[Value] =
    let o = L.checkTable(a, 1, "exec")
    let s = sshFromOpts(o)
    let (outp, code) = L.runTool(s, "ssh", s.baseOpts("-p") & @[s.target, optField(o, "command", "")])
    @[strV(outp), intV(code)]
  tableV(m)

proc openSftp(L: Interp): Value =
  # " sftp " partage les sessions de " ssh " (transferts get/put/list...).
  L.openPackage("ssh")

const sshDocs = [
  "ssh.connect{host=, user=, port=22, key=, password=, options={}}", "Ouvre une session (vérifie la connexion). Authentification par clé ; password demande sshpass.",
  "ssh.exec{host=, user=, command=, ...}", "Exécute une commande sans garder de session : sortie, code.",
  "session:exec(command)", "Exécute une commande distante : sortie, code de retour.",
  "session:get(remote, [localpath])", "Télécharge un fichier ou dossier (scp).",
  "session:put(localpath, [remote])", "Envoie un fichier ou dossier (scp).",
  "session:list([path])", "Noms d'un dossier distant (sftp).",
  "session:mkdir(path)", "Crée un dossier distant (sftp).", "session:rmdir(path)", "Supprime un dossier distant (sftp).",
  "session:remove(path)", "Supprime un fichier distant (sftp).", "session:rename(old, new)", "Renomme (sftp)."]

registerPackage PackageDef(name: "ssh", open: openSsh,
  description: "SSH (client OpenSSH)", docs: docs("ssh", sshDocs))
registerPackage PackageDef(name: "sftp", open: openSftp,
  description: "SFTP : mêmes sessions que ssh", docs: docs("sftp", [
    "sftp.connect{host=, user=, port=22, key=, password=}", "Ouvre une session de transfert (identique à ssh.connect)."]))
