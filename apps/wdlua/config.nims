# wdlua est prévu pour vivre dans apps/wdlua du dépôt nim.wdgui (comme wdnim, wdnotes, wdreka,...).
# Si wdgui est déplacé dans le projet, penser à remplacer le chemin ci-dessous.
switch("path", "../../src")
switch("threads", "on")
switch("mm", "atomicArc")
switch("define", "sdlttf")
switch("define", "ssl")          # HTTPS et TLS (OpenSSL chargé à l'exécution).
switch("stackTrace", "on")
