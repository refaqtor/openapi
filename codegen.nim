import macros
import tables
import json
import strutils
import options
import hashes
import strtabs

import spec
import parser
import paths

from schema2 import OpenApi2

type
  PathItem* = object of ConsumeResult
    path*: string
    parsed*: ParserResult
    basePath*: string
    host*: string
    operations*: Table[string, Operation]
    parameters*: Parameters
    roottype*: NimNode

  ParameterIn = enum
    InQuery = "query"
    InBody = "body"
    InHeader = "header"
    InPath = "path"
    InData = "formData"

  Parameter = object of ConsumeResult
    name*: string
    description*: string
    required*: bool
    location*: ParameterIn
    default*: JsonNode
    source*: JsonNode
    kind*: Option[GuessTypeResult]

  Parameters = object
    sane: StringTableRef
    tab: Table[Hash, Parameter]
    forms: set[ParameterIn]

  Response = object of ConsumeResult
    status: string
    description: string

  Operation = object of ConsumeResult
    meth*: HttpOpName
    path*: string
    description*: string
    operationId*: string
    parameters*: Parameters
    responses*: seq[Response]
    deprecated*: bool
    typename*: NimNode
    prepname*: NimNode

proc newParameter(root: JsonNode; input: JsonNode): Parameter =
  ## instantiate a new parameter from a JsonNode schema
  assert input != nil and input.kind == JObject, "bizarre input: " &
    input.pretty
  var
    js = root.pluckRefJson(input)
    documentation = input.pluckString("description")
  if js == nil:
    js = input
  elif documentation.isNone:
    documentation = js.pluckString("description")
  var kind = js.guessType(root)
  if kind.isNone:
    error "unable to guess type:\n" & js.pretty
  result = Parameter(ok: false, kind: kind, js: js)
  result.name = js["name"].getStr
  result.location = parseEnum[ParameterIn](js["in"].getStr)
  result.required = js.getOrDefault("required").getBool
  if documentation.isSome:
    result.description = documentation.get()
  result.default = js.getOrDefault("default")

  # `source` is a pointer to the JsonNode that defines the
  # format for the parameter; it can be overridden with `schema`
  if result.location == InBody and "schema" notin js:
    error "schema is required for " & $result & "\n" & js.pretty
  elif result.location != InBody and "schema" in js:
    error "schema is inappropriate for " & $result & "\n" & js.pretty
  while "schema" in js:
    js = js["schema"]
    var source = root.pluckRefJson(js)
    if source == nil:
      break
    js = source
  if result.source == nil:
    result.source = js

  result.ok = true

template cappableAdd(s: var string; c: char) =
  ## add a char to a string, perhaps capitalizing it
  if s.len > 0 and s[^1] == '_':
    s.add c.toUpperAscii()
  else:
    s.add c

proc sanitizeIdentifier(name: string; capsOkay=false): Option[string] =
  ## convert any string to a valid nim identifier in camel_Case
  const elideUnder = true
  var id = ""
  if name.len == 0:
    return
  for c in name:
    if id.len == 0:
      if c in IdentStartChars:
        id.cappableAdd c
        continue
    elif c in IdentChars:
      id.cappableAdd c
      continue
    # help differentiate words case-insensitively
    id.add '_'
  when not elideUnder:
    while "__" in id:
      id = id.replace("__", "_")
  if id.len > 1:
    id.removeSuffix {'_'}
    id.removePrefix {'_'}
  # if we need to lowercase the first letter, we'll lowercase
  # until we hit a word boundary (_, digit, or lowercase char)
  if not capsOkay and id[0].isUpperAscii:
    for i in id.low..id.high:
      if id[i] in ['_', id[i].toLowerAscii]:
        break
      id[i] = id[i].toLowerAscii
  # ensure we're not, for example, starting with a digit
  if id[0] notin IdentStartChars:
    warning "identifiers cannot start with `" & id[0] & "`"
    return
  when elideUnder:
    if id.len > 1:
      while "_" in id:
        id = id.replace("_", "")
  if not id.isValidNimIdentifier:
    warning "bad identifier: " & id
    return
  result = some(id)

proc saneName(param: Parameter): string =
  ## produce a safe identifier for the given parameter
  let id = sanitizeIdentifier(param.name, capsOkay=true)
  if id.isNone:
    error "unable to compose valid identifier for parameter `" & param.name & "`"
  result = id.get()

proc saneName(op: Operation): string =
  ## produce a safe identifier for the given operation
  var attempt: seq[string]
  if op.operationId != "":
    attempt.add op.operationId
    attempt.add $op.meth & "_" & op.operationId
  # TODO: turn path /some/{var_name}/foo_bar into some_varName_fooBar?
  attempt.add $op.meth & "_" & op.path
  for name in attempt:
    var id = sanitizeIdentifier(name, capsOkay=false)
    if id.isSome:
      return id.get()
  error "unable to compose valid identifier; attempted these: " & attempt.repr

proc `$`*(path: PathItem): string =
  ## render a path item for error message purposes
  if path.host != "":
    result = path.host
  if path.basePath != "/":
    result.add path.basePath
  result.add path.path

proc `$`*(op: Operation): string =
  ## render an operation for error message purposes
  result = op.saneName

proc `$`*(param: Parameter): string =
  result = $param.saneName & "(" & $param.location & "-`" & param.name & "`)"

proc hash(p: Parameter): Hash =
  ## parameter cardinality is a function of name and location
  result = p.location.hash !& p.name.hash
  result = !$result

proc len(parameters: Parameters): int =
  ## the number of items in the container
  result = parameters.tab.len

iterator items(parameters: Parameters): Parameter =
  ## helper for iterating over parameters
  for p in parameters.tab.values:
    yield p

iterator forLocation(parameters: Parameters; loc: ParameterIn): Parameter =
  ## iterate over parameters with the given location
  if loc in parameters.forms:
    for p in parameters:
      if p.location == loc:
        yield p

iterator nameClashes(parameters: Parameters; p: Parameter): Parameter =
  ## yield clashes that don't produce parameter "overrides" (identity)
  let name = p.saneName
  if name in parameters.sane:
    for existing in parameters:
      # identical parameter names can be ignored
      if existing.name == p.name:
        if existing.location == p.location:
          continue
      # yield only identifier collisions
      if name.eqIdent(existing.saneName):
        warning "name `" & p.name & "` versus `" & existing.name & "`"
        warning "sane `" & name & "` matches `" & existing.saneName & "`"
        yield existing

proc add(parameters: var Parameters; p: Parameter) =
  ## simpler add explicitly using hash
  let
    location = $p.location
    name = p.saneName

  parameters.sane[name] = location
  parameters.tab[p.hash] = p
  parameters.forms.incl p.location

proc safeAdd(parameters: var Parameters; p: Parameter; prefix=""): Option[string] =
  ## attempt to add a parameter to the container, erroring if it clashes
  for clash in parameters.nameClashes(p):
    # this could be a replacement/override of an existing parameter
    if clash.location == p.location:
      # the names have to match, not just their identifier versions
      if clash.name == p.name:
        continue
    # otherwise, we should probably figure out alternative logic
    var msg = "parameter " & $clash & " and " & $p &
      " yield the same Nim identifier"
    if prefix != "":
      msg = prefix & ": " & msg
    return some(msg)
  parameters.add p

proc initParameters(parameters: var Parameters) =
  ## prepare a parameter container to accept parameters
  parameters.sane = newStringTable(modeStyleInsensitive)
  parameters.tab = initTable[Hash, Parameter]()
  parameters.forms = {}

proc readParameters(root: JsonNode; js: JsonNode): Parameters =
  ## parse parameters out of an arbitrary JsonNode
  result.initParameters()
  for param in js:
    var parameter = root.newParameter(param)
    if not parameter.ok:
      error "bad parameter:\n" & param.pretty
      continue
    result.add parameter

proc newResponse(root: JsonNode; status: string; input: JsonNode): Response =
  ## create a new Response
  var js = root.pluckRefJson(input)
  if js == nil:
    js = input
  result = Response(ok: false, status: status, js: js)
  result.description = js.getOrDefault("description").getStr
  # TODO: save the schema
  result.ok = true

proc toJsonParameter(name: NimNode; required: bool): NimNode =
  ## create the right-hand side of a JsonNode typedef for the given parameter
  if required:
    result = newIdentDefs(name, newIdentNode("JsonNode"))
  else:
    result = newIdentDefs(name, newIdentNode("JsonNode"), newNilLit())

proc toNewJsonNimNode(js: JsonNode): NimNode =
  ## take a JsonNode value and produce Nim that instantiates it
  case js.kind:
  of JNull:
    result = quote do: newJNull()
  of JInt:
    let i = js.getInt
    result = quote do: newJInt(`i`)
  of JString:
    let s = js.getStr
    result = quote do: newJString(`s`)
  of JFloat:
    let f = js.getFloat
    result = quote do: newJFloat(`f`)
  of JBool:
    let b = newIdentNode($js.getBool)
    result = quote do: newJBool(`b`)
  of JArray:
    var
      a = newNimNode(nnkBracket)
      t: JsonNodeKind
    for i, j in js.getElems:
      if i == 0:
        t = j.kind
      elif t != j.kind:
        warning "disparate JArray element kinds are discouraged"
      else:
        a.add j.toNewJsonNimNode
    var
      c = newStmtList()
      i = newIdentNode("jarray")
    c.add quote do:
      var `i` = newJarray()
    for j in a:
      c.add quote do:
        `i`.add `j`
    c.add quote do:
      `i`
    result = newBlockStmt(c)
  else:
    raise newException(ValueError, "unsupported input: " & $js.kind)

proc shortRepr(js: JsonNode): string =
  ## render a JInt(3) as "JInt(3)"; will puke on arrays/objects/null
  result = $js.kind & "(" & $js & ")"

proc defaultNode(op: Operation; param: Parameter; root: JsonNode): NimNode =
  ## generate nim to instantiate the default value for the parameter
  var useDefault = false
  if param.default != nil:
    let
      sane = param.saneName
    if param.kind.isNone:
      warning "unable to parse default value for parameter `" & sane &
      "`:\n" & param.js.pretty
    elif param.kind.get().major == param.default.kind:
      useDefault = true
    else:
      # provide a warning if the default type doesn't match the input
      warning "`" & sane & "` parameter in `" & $op &
        "` is " & $param.kind.get().major & " but the default is " &
        param.default.shortRepr & "; omitting code to supply the default"

  if useDefault:
    # set default value for input
    try:
      result = param.default.toNewJsonNimNode
    except ValueError as e:
      error e.msg & ":\n" & param.default.pretty
    assert result != nil
  else:
    result = newNilLit()

proc documentation(p: Parameter; root: JsonNode; name=""): NimNode =
  ## document the given parameter
  var
    label = if name == "": p.name else: name
    docs = "  " & label & ": "
  if p.kind.isNone:
    docs &= "{unknown type}"
  else:
    docs &= $p.kind.get().major
  if p.required:
    docs &= " (required)"
  if p.description != "":
    docs &= "\n" & spaces(2 + label.len) & ": "
    docs &= p.description
  result = newCommentStmtNode(docs)

proc sectionParameter(param: Parameter; kind: JsonNodeKind; section: NimNode; default: NimNode = nil): NimNode =
  ## pluck value out of location input, validate it, store it in section ident
  result = newStmtList([])
  var
    name = param.name
    reqIdent = newIdentNode($param.required)
    locIdent = newIdentNode($param.location)
    validIdent = genSym(ident="valid")
    defNode = if default == nil: newNilLit() else: default
    kindIdent = newIdentNode($kind)
  # you might think `locIdent`.getOrDefault() would be a good place to simply
  # instantiate our default JsonNode, but the validateParameter() is a more
  # central place to validate/log both the input and the default value,
  # particularly since we aren't going to unwrap the 'body' parameter

  # "there can be one 'body' parameter at most."
  if param.location == InBody:
    result.add quote do:
      `section` = validateParameter(`locIdent`, `kindIdent`,
        required= `reqIdent`, default= `defNode`)
  else:
    result.add quote do:
      var `validIdent` = `locIdent`.getOrDefault(`name`)
      `validIdent` = validateParameter(`validIdent`, `kindIdent`,
        required= `reqIdent`, default= `defNode`)
      if `validIdent` != nil:
        `section`.add `name`, `validIdent`

proc maybeAddExternalDocs(node: var NimNode; js: JsonNode) =
  ## add external docs comments to the given node if appropriate
  if js == nil or "externalDocs" notin js:
    return
  for field in ["description", "url"]:
    var comment = js["externalDocs"].pluckString(field)
    if comment.isSome:
      node.add newCommentStmtNode(comment.get())

proc maybeDeprecate(name: NimNode; params: seq[NimNode]; body: NimNode;
                    deprecate: bool): NimNode =
  ## make a proc and maybe deprecate it
  if deprecate:
    var pragmas = newNimNode(nnkPragma)
    pragmas.add newIdentNode("deprecated")
    result = newProc(name, params, body, pragmas = pragmas)
  else:
    result = newProc(name, params, body)

proc locationParamDefs(op: Operation): seq[NimNode] =
  ## produce a list of name/value parameters for each location
  result = @[newIdentNode("JsonNode")]
  for location in ParameterIn.low..ParameterIn.high:
    var locIdent = newIdentNode($location)
    # we require all locations for signature reasons
    result.add locIdent.toJsonParameter(required=false)

proc makeProcWithLocationInputs(op: Operation; name: NimNode; root: JsonNode): Option[NimNode] =
  ## create a proc to validate and compose inputs for a given call
  let
    output = newIdentNode("result")
    section = newIdentNode("section")
  var
    body = newStmtList()

  # add documentation if available
  if op.description != "":
    body.add newCommentStmtNode(op.description & "\n")
  body.maybeAddExternalDocs(op.js)

  # all of these procs need all sections for consistency
  body.add quote do:
    var `section`: JsonNode

  body.add quote do:
    `output` = newJObject()

  for location in ParameterIn.low..ParameterIn.high:
    var
      required: bool
      loco = $location
      locIdent = newIdentNode(loco)
    required = false
    if location in op.parameters.forms:
      body.add newCommentStmtNode("parameters in `" & loco & "` object:")
    for param in op.parameters.forLocation(location):
      body.add param.documentation(root)

    # the body IS the section, so don't bother creating a JObject for it
    if location != InBody:
      body.add quote do:
        `section` = newJObject()

    for param in op.parameters.forLocation(location):
      var
        default = op.defaultNode(param, root)
      if param.kind.isNone:
        warning "failure to infer type for parameter " & $param
        return
      if not required:
        required = required or param.required
        if required:
          var msg = loco & " argument is necessary"
          if location != InBody:
            msg &= " due to required `" & param.name & "` field"
          body.add quote do:
            assert `locIdent` != nil, `msg`
      body.add param.sectionParameter(param.kind.get().major, section, default=default)

    if location == InBody:
      # don't attempt to save a nil body to the result
      body.add quote do:
        if `section` != nil:
          `output`.add `loco`, `section`
    else:
      # if it's not a body, we don't need to check if it's nil
      body.add quote do:
        `output`.add `loco`, `section`

  let params = op.locationParamDefs
  result = some(maybeDeprecate(name, params, body, deprecate=op.deprecated))

proc namedParamDefs(op: Operation): seq[NimNode] =
  ## produce a list of name/value parameters per each operation input
  # add required params first,
  for param in op.parameters:
    if param.required:
      var
        sane = param.saneName
        saneIdent = sane.stropIfNecessary
      result.add saneIdent.toJsonParameter(param.required)
  # then add optional params
  for param in op.parameters:
    if not param.required:
      var
        sane = param.saneName
        saneIdent = sane.stropIfNecessary
      result.add saneIdent.toJsonParameter(param.required)

proc makeProcWithNamedArguments(op: Operation; callType: NimNode; root: JsonNode): Option[NimNode] =
  ## create a proc to validate and compose inputs for a given call
  let
    name = newExportedIdentNode("call")
    validIdent = newIdentNode("valid")
    callName = genSym(ident="call")
  var
    body = newStmtList()

  # add documentation if available
  body.add newCommentStmtNode(op.saneName)
  if op.description != "":
    body.add newCommentStmtNode(op.description)
  body.maybeAddExternalDocs(op.js)

  # document the parameters
  for param in op.parameters:
    body.add param.documentation(root, name=param.saneName)

  let inputsIdent = newIdentNode("result")
  if op.parameters.len > 0:
    body.add quote do:
      var `validIdent`: JsonNode
  body.add quote do:
    `inputsIdent` = newJObject()

  # assert proper parameter types and/or set defaults
  for param in op.parameters:
    var
      insane = param.name
      sane = param.saneName
      saneIdent = sane.stropIfNecessary
      reqIdent = newIdentNode($param.required)
      default = op.defaultNode(param, root)
      errmsg: string
    if param.kind.isNone:
      warning "failure to infer type for parameter " & $param
      return
    var
      kindIdent = newIdentNode($param.kind.get().major)
    errmsg = "expected " & $param.kind.get().major & " for `" & sane & "` but received "
    for clash in op.parameters.nameClashes(param):
      warning "identifier clash in proc arguments: " & $clash.location &
        "-`" & clash.name & "` versus " & $param.location & "-`" &
        param.name & "`"
      return
    body.add quote do:
      `validIdent` = validateParameter(`saneIdent`, `kindIdent`,
        required=`reqIdent`, default=`default`)
    if param.required:
      body.add quote do:
        `inputsIdent`.add(`insane`, `validIdent`)
    else:
      body.add quote do:
        if `validIdent` != nil:
          `inputsIdent`.add(`insane`, `validIdent`)

  var
    params = @[newIdentNode("JsonNode")]
  params.add newIdentDefs(callName, callType)
  params &= op.namedParamDefs
  result = some(maybeDeprecate(name, params, body, deprecate=op.deprecated))

proc makeCallType(path: PathItem; op: Operation): NimNode =
  let
    saneType = op.typename
    oac = path.roottype
  result = quote do:
    type
      `saneType` = ref object of `oac`

proc makeCall(path: PathItem; op: Operation): NimNode =
  ## produce an instantiated call object for export
  let
    sane = op.saneName
    meth = $op.meth
    methId = newIdentNode("HttpMethod.Http" & meth.capitalizeAscii)
    saneCall = newExportedIdentNode(sane)
    saneType = op.typename
    validId = op.prepname
    host = path.host
    route = path.basePath & path.path

  result = quote do:
    var `saneCall` = `saneType`(name: `sane`, meth: `methId`, host: `host`,
                                path: `route`, validator: `validId`)

proc newOperation(path: PathItem; meth: HttpOpName; root: JsonNode; input: JsonNode): Operation =
  ## create a new operation for a given http method on a given path
  var
    response: Response
    js = root.pluckRefJson(input)
    documentation = input.pluckString("description")
  if js == nil:
    js = input
  # if the ref has a description, use that if needed
  elif documentation.isNone:
    documentation = input.pluckString("description")
  result = Operation(ok: false, meth: meth, path: path.path, js: js)
  if documentation.isSome:
    result.description = documentation.get()
  result.operationId = js.getOrDefault("operationId").getStr
  if result.operationId == "":
    var msg = "operationId not defined for " & toUpperAscii($meth)
    if path.path == "":
      msg = "empty path and " & msg
      error msg
      return
    else:
      msg = msg & " on `" & path.path & "`"
      warning msg
      let sane = result.saneName
      warning "invented operation name `" & sane & "`"
      result.operationId = sane
  let sane = result.saneName
  result.typename = genSym(ident="Call_" & sane.capitalizeAscii)
  result.prepname = genSym(ident="validate_" & sane.capitalizeAscii)
  if "responses" in js:
    for status, resp in js["responses"].pairs:
      response = root.newResponse(status, resp)
      if response.ok:
        result.responses.add response
      else:
        warning "bad response:\n" & resp.pretty

  result.parameters.initParameters()
  # inherited parameters from the PathItem
  for parameter in path.parameters:
    var badadd = result.parameters.safeAdd(parameter, sane)
    if badadd.isSome:
      warning badadd.get()
      result.parameters.add parameter
  # parameters for this particular http method
  if "parameters" in js:
    for parameter in root.readParameters(js["parameters"]):
      if parameter.location == InPath:
        let parsed = parseTemplate(path.path)
        if not parsed.ok:
          error $parameter & " provided but path `" & $path & "` invalid"
        if parameter.name notin parsed.variables:
          error $parameter & " provided but not in path `" & $path & "`"
      var badadd = result.parameters.safeAdd(parameter, sane)
      if badadd.isSome:
        warning badadd.get()
        result.parameters.add parameter

  result.ast = newStmtList()

  # start with the call type
  result.ast.add path.makeCallType(result)

  # if we don't have locations, we cannot support the operation at all
  let locations = result.makeProcWithLocationInputs(result.prepname, root)
  if locations.isNone:
    warning "unable to compose `" & sane & "`"
    return
  result.ast.add locations.get()

  # we use the call type to make our call() operation with named args
  let namedArgs = result.makeProcWithNamedArguments(result.typename, root)
  if namedArgs.isSome:
    result.ast.add namedArgs.get()

  # finally, add the call variable that the user hooks to
  result.ast.add path.makeCall(result)
  result.ok = true

proc newPathItem(root: JsonNode; oac: NimNode; path: string; input: JsonNode): PathItem =
  ## create a PathItem result for a parsed node
  var
    op: Operation
  result = PathItem(ok: false, roottype: oac, path: path, js: input)
  if root != nil and root.kind == JObject and "basePath" in root:
    if root["basePath"].kind == JString:
      result.basePath = root["basePath"].getStr
  if root != nil and root.kind == JObject and "host" in root:
    if root["host"].kind == JString:
      result.host = root["host"].getStr
  if input == nil or input.kind != JObject:
    error "unimplemented path item input:\n" & input.pretty
    return
  if "$ref" in input:
    error "path item $ref is unimplemented:\n" & input.pretty
    return

  # record default parameters for the path
  if "parameters" in input:
    result.parameters = root.readParameters(input["parameters"])

  # look for operation names in the input
  for opName in HttpOpName:
    if $opName notin input:
      continue
    op = result.newOperation(opName, root, input[$opName])
    if not op.ok:
      warning "unable to parse " & $opName & " on " & path
      continue
    result.operations[$opName] = op
  result.ok = true

iterator paths(root: JsonNode; oac: NimNode; ftype: FieldTypeDef): PathItem =
  ## yield path items found in the given node
  var
    schema: Schema
    pschema: Schema = nil

  assert ftype.kind == Complex, "malformed schema: " & $ftype.schema

  while "paths" in ftype.schema:
    # make sure our schema is sane
    if ftype.schema["paths"].kind == Complex:
      pschema = ftype.schema["paths"].schema
    else:
      error "malformed paths schema: " & $ftype.schema["paths"]
      break

    # make sure our input is sane
    if root == nil or root.kind != JObject:
      warning "missing or invalid json input: " & $root
      break
    if "paths" notin root or root["paths"].kind != JObject:
      warning "missing or invalid paths in input: " & $root["paths"]
      break

    # find a good schema definition for ie. /{name}
    for k, v in pschema.pairs:
      if not k.startsWith("/"):
        warning "skipped invalid path: `" & k & "`"
        continue
      schema = v.schema
      break

    # iterate over input and yield PathItems per each node
    for k, v in root["paths"].pairs:
      # spec says valid paths should start with /
      if not k.startsWith("/"):
        if not k.toLower.startsWith("x-"):
          warning "unrecognized path: " & k
        continue
      yield root.newPathItem(oac, k, v)
    break

proc prefixedPluck(js: JsonNode; field: string; indent=0): string =
  result = indent.spaces & field & ": "
  result &= js.pluckString(field).get("(not provided)") & "\n"

proc renderLicense(js: JsonNode): string =
  ## render a license section for the preamble
  result = "license:"
  if js == nil:
    return result & " (not provided)\n"
  result &= "\n"
  for field in ["name", "url"]:
    result &= js.prefixedPluck(field, 4)

proc renderPreface(js: JsonNode): string =
  ## produce a preamble suitable for documentation
  result = "auto-generated via openapi macro\n"
  if "info" in js:
    let
      info = js["info"]
    for field in ["title", "version", "termsOfService"]:
      result &= info.prefixedPluck(field)
    result &= info.getOrDefault("license").renderLicense
    result &= "\n" & info.pluckString("description").get("") & "\n"

proc preamble(oac: NimNode): NimNode =
  ## code common to all apis
  result = newStmtList([])

  # imports
  var imports = newNimNode(nnkImportStmt)
  for module in ["json", "openapi/rest"]:
    imports.add newIdentNode(module)
  result.add imports

  # exports
  when false:
    var exports = newNimNode(nnkExportStmt)
    exports.add newIdentNode("rest")
    result.add exports

  let
    jsP = newIdentNode("js")
    kindP = newIdentNode("kind")
    requiredP = newIdentNode("required")
    defaultP = newIdentNode("default")
    queryP = newIdentNode("query")
    bodyP = newIdentNode("body")
    pathP = newIdentNode("path")
    headerP = newIdentNode("header")
    formP = newIdentNode("formData")
    vsP = newIdentNode("ValidatorSignature")
    tP = newIdentNode("t")
    createP = newIdentNode("clone")
    T = newIdentNode("T")
    dollP = newIdentNode("`$`")

  result.add quote do:
    type
      `vsP` = proc (`queryP`: JsonNode = nil; `bodyP`: JsonNode = nil;
         `headerP`: JsonNode = nil; `pathP`: JsonNode = nil;
         `formP`: JsonNode = nil): JsonNode
      `oac` = ref object of RestCall
        validator*: `vsP`
        path*: string
        host*: string

    proc `dollP`*(`bodyP`: `oac`): string = rest.`dollP`(`bodyP`)

    proc `createP`*[`T`: `oac`](`tP`: `T`): `T` =
      result = T(name: `tP`.name, meth: `tP`.meth, host: `tP`.host,
                 path: `tP`.path, validator: `tP`.validator)

    proc validateParameter(`jsP`: JsonNode; `kindP`: JsonNodeKind;
      `requiredP`: bool; `defaultP`: JsonNode = nil): JsonNode =
      ## ensure an input is of the correct json type and yield
      ## a suitable default value when appropriate
      if `jsP` == nil:
        if `defaultP` != nil:
          return validateParameter(`defaultP`, `kindP`,
            required=`requiredP`)
      result = `jsP`
      if result == nil:
        assert not `requiredP`, $`kindP` & " expected; received nil"
        if `requiredP`:
          result = newJNull()
      else:
        assert `jsP`.kind == `kindP`,
          $`kindP` & " expected; received " & $`jsP`.kind

proc consume(content: string): ConsumeResult {.compileTime.} =
  ## parse a string which might hold an openapi definition
  when false:
    var
      parsed: ParserResult
      schema: FieldTypeDef
      typedefs: seq[FieldTypeDef]
      tree: WrappedField

  result = ConsumeResult(ok: false)

  while true:
    try:
      result.js = content.parseJson()
      if result.js.kind != JObject:
        error "i was expecting a json object, but i got " &
          $result.js.kind
        break
    except JsonParsingError as e:
      error "error parsing the input as json: " & e.msg
      break
    except ValueError:
      error "json parsing failed, probably due to an overlarge number"
      break

    if "swagger" in result.js:
      if result.js["swagger"].getStr != "2.0":
        error "we only know how to parse openapi-2.0 atm"
        break
      result.schema = OpenApi2
    else:
      error "no swagger version found in the input"
      break

    let pr = result.schema.parseSchema(result.js)
    if not pr.ok:
      break

    result.ast = newStmtList []
    result.ast.add newCommentStmtNode(result.js.renderPreface)
    result.ast.maybeAddExternalDocs(result.js)

    # add common code
    let oac = genSym(ident="OpenApiRestCall")
    result.ast.add preamble(oac)

    # deprecated
    when false:
      tree = newBranch[FieldTypeDef, WrappedItem](anything({}), "tree")
      tree["definitions"] = newBranch[FieldTypeDef, WrappedItem](anything({}), "definitions")
      tree["parameters"] = newBranch[FieldTypeDef, WrappedItem](anything({}), "parameters")
      if "definitions" in result.js:
        let
          definitions = result.schema["definitions"]
        typedefs = toSeq(definitions.schema.values)
        assert typedefs.len == 1, "dunno what to do with " &
          $typedefs.len & " definitions schemas"
        schema = typedefs[0]
        var
          typeSection = newNimNode(nnkTypeSection)
          deftree = tree["definitions"]
        for k, v in result.js["definitions"]:
          parsed = v.parsePair(k, schema)
          if not parsed.ok:
            error "parse error on definition for " & k
            break
          for wrapped in parsed.ftype.wrapOneType(k, v):
            if wrapped.name in deftree:
              warning "not redefining " & wrapped.name
              continue
            case wrapped.kind:
            of Primitive:
              deftree[k] = newLeaf(parsed.ftype, k, wrapped)
            of Complex:
              deftree[k] = newBranch[FieldTypeDef, WrappedItem](parsed.ftype, k)
            else:
              error "can't grok " & k & " of type " & $wrapped.kind
          var onedef = schema.makeTypeDef(k, input=v)
          if onedef.ok:
            typeSection.add onedef.ast
          else:
            warning "unable to make typedef for " & k
          result.ast.add typeSection

    # add whatever we can for each operation
    for path in result.js.paths(oac, result.schema):
      for meth, op in path.operations.pairs:
        result.ast.add op.ast

    result.ok = true
    break

macro openapi*(inputfn: static[string]; outputfn: static[string]=""; body: untyped): untyped =
  ## parse input json filename and output nim target library
  # TODO: this should get renamed to openApiClient to make room for openApiServer
  let content = staticRead(`inputfn`)
  var consumed = content.consume()
  if consumed.ok == false:
    error "unable to parse " & `inputfn`
    return
  result = consumed.ast
  if body != nil:
    result.add body

  if `outputfn` == "":
    hint "provide filename.nim to save Nim source"
  elif not `outputfn`.endsWith(".nim"):
    hint "i'm afraid to overwrite " & `outputfn`
  else:
    hint "writing " & `outputfn`
    writeFile(outputfn, result.repr)
    result = newNimNode(nnkImportStmt)
    result.add newStrLitNode(outputfn)
