# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   _._
# o|- -|o  wdnotes - export facade
#  ( l )
#    =

import std/[os, strutils]
import render, exp_html, exp_pdf, exp_rtf, exp_odt
export render

type ExportKind* = enum exPdf = "pdf", exHtml = "html", exRtf = "rtf", exOdt = "fodt"

const ExportFilters* = [
  exPdf: "Document PDF|*.pdf",
  exHtml: "Site HTML (dossier)|*",
  exRtf: "Rich Text Format|*.rtf",
  exOdt: "LibreOffice Writer (Flat ODT)|*.fodt"]

proc parseExportKind*(s: string): ExportKind =
  case s.toLowerAscii
  of "pdf": exPdf
  of "html", "htm", "web": exHtml
  of "rtf": exRtf
  of "odt", "fodt", "libreoffice", "lo": exOdt
  else: raise newException(ValueError, "format inconnu : " & s)

proc fixExtension*(path: string, kind: ExportKind): string =
  if kind == exHtml: return path
  let ext = "." & $kind
  if path.toLowerAscii.endsWith(ext): path else: path.changeFileExt(ext)

proc exportDoc*(doc: RenderDoc, kind: ExportKind, path: string): string =
  # writes the document; returns the path of the main file produced.
  case kind
  of exPdf:
    result = fixExtension(path, kind)
    exportPdf(doc, result)
  of exHtml:
    exportHtml(doc, path)
    result = path / "index.html"
  of exRtf:
    result = fixExtension(path, kind)
    exportRtf(doc, result)
  of exOdt:
    result = fixExtension(path, kind)
    exportFodt(doc, result)
