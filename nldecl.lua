require 'dumper'.import()

-- TODO: better handle reserved names everywhere

local gcc = require 'gcc'
local Emitter = require 'emitter'
local gccutils = require 'gccutils'
local chain = gccutils.chain

local nldecl = {}
local emitter = Emitter()
nldecl.emitter = emitter
nldecl.include_names = {}
nldecl.exclude_names = {}
nldecl.generalize_pointers = {}
nldecl.include_filters = {}
nldecl.exclude_filters = {}
nldecl.predeclared_names = {}
nldecl.declared_names = {}

function nldecl.can_decl(declname, forwarddecl)
  if not declname or #declname == 0 then
    -- invalid declname
    return false
  end
  if not forwarddecl and nldecl.declared_names[declname] then
    -- already declared
    return false
  end
  if forwarddecl and nldecl.predeclared_names[declname] then
    -- already declared
    return false
  end
  if nldecl.exclude_names[declname] then
    -- ignored
    return false
  end
  if nldecl.include_names[declname] then
    -- accept declaration
    return true
  end
  if #nldecl.exclude_filters > 0 then
    for _,patt in ipairs(nldecl.exclude_filters) do
      if declname:match(patt) then
        return false
      end
    end
  end
  if #nldecl.include_filters > 0 then
    for _,patt in ipairs(nldecl.include_filters) do
      if declname:match(patt) then
        return true
      end
    end
    return false
  else
    return true
  end
end

local function visit(node, ...)
  -- try hooks first
  local kind = node:code()
  local visitor = nldecl[kind .. '_hook']
  if visitor and visitor(node, ...) then
    -- hooked
    return
  end
  visitor = nldecl[kind]
  if not visitor then
    error('cannot visit node ' .. kind)
  end
  visitor(node, ...)
end

local function scalar_type(node, decl)
  local typename = gccutils.get_id(node)
  if not decl and typename and nldecl.include_names[typename] then
    emitter:add(typename)
  else
    local nltype = gccutils.node_ctype2nltype(node)
    if not nltype then error('unknown ctype ' .. tostring(gccutils.get_id(node))) end
    emitter:add(nltype)
  end
end

nldecl.integer_type = scalar_type
nldecl.real_type = scalar_type

function nldecl.pointer_type(node, decl)
  local subnode = node:type()
  local typename = gccutils.get_id(node)
  if not decl and typename then
    emitter:add(typename)
  else
    if nldecl.generalize_pointers[gccutils.get_id(subnode)] then
      emitter:add('pointer')
      return
    end
    if subnode:code() == 'integer_type' and gccutils.get_id(subnode:canonical()) == 'char' then
      emitter:add('cstring')
    elseif subnode:code() == 'void_type' then
      emitter:add('pointer')
    elseif subnode:code() == 'function_type' then
      visit(subnode)
    else
      emitter:add('*')
      visit(subnode)
    end
  end
end

function nldecl.boolean_type(node, decl)
  emitter:add('boolean')
end

function nldecl.void_type(_)
  emitter:add('void')
end

local function visit_fields(node)
  local unnamedcount = 1
  for fieldnode in chain(node:fields()) do
    local fieldname = fieldnode:name() and fieldnode:name():value()
    local fieldtype = fieldnode:type()
    local annotations = {}
    if fieldnode:bit_field() then
      fieldtype = fieldnode:bit_field_type()
      --local bitfieldsize = fieldnode:size():value()
      --table.insert(annotations, string.format('bitsize(%d)', bitfieldsize))
    end
    if fieldname then
      fieldname = gccutils.normalize_name(fieldname)
      emitter:add_indent(fieldname .. ': ')
    else
      emitter:add_indent('__unnamed' .. unnamedcount .. ': ')
      unnamedcount = unnamedcount + 1
      --table.insert(annotations, 'cunnamed')
    end
    visit(fieldtype)
    if #annotations > 0 then
      emitter:add(' <'..table.concat(annotations, ', ')..'>')
    end
    if not fieldnode:chain() then -- last field
      emitter:add_ln()
    else
      emitter:add_ln(',')
    end
  end
end

function nldecl.record_type(node, decl)
  local typename = gccutils.get_id(node)
  if not decl and typename then
    assert(not node:anonymous())
    emitter:add(typename)
    return
  elseif not node:fields() then
    emitter:add('record{}')
    return
  end
  emitter:add_ln('record{')
  emitter:inc_indent()
  visit_fields(node)
  emitter:dec_indent()
  emitter:add_indent('}')
end

function nldecl.union_type(node, decl)
  local typename = gccutils.get_id(node)
  if not decl and typename then
    assert(not node:anonymous())
    emitter:add(typename)
    return
  elseif not node:fields() then
    emitter:add('union{}')
    return
  end
  emitter:add_ln('record{')
  -- TODO: proper union
  -- emitter:add_ln('union{')
  emitter:inc_indent()
  visit_fields(node)
  emitter:dec_indent()
  emitter:add_indent('}')
end

function nldecl.enumeral_type(node, decl)
  -- enum may be cint or cuint depending on the values
  local named = not node:anonymous()
  if not decl then
    if named then
      local typename = gccutils.get_id(node)
      assert(typename)
      emitter:add(typename)
    else
      local nltype = gccutils.get_enum_nltype(node)
      emitter:add(nltype)
    end
    return
  end
  assert(named)
  local nltype = gccutils.get_enum_nltype(node)
  emitter:add_ln('enum('..nltype..'){')
  emitter:inc_indent()
  for fieldnode in chain(node:values()) do
    local fieldname = fieldnode:purpose():value()
    local fieldvalue = fieldnode:value():value()
    emitter:add_indent(fieldname..' = '..fieldvalue)
    if not fieldnode:chain() then -- last node
      emitter:add_ln()
    else
      emitter:add_ln(',')
    end
  end
  emitter:dec_indent()
  emitter:add_indent('}')
end

function nldecl.vector_type(node)
  local subtype = node:type()
  local len = node:size():value() // subtype:size():value()
  emitter:add(string.format('[%d]',len))
  visit(subtype)
end

function nldecl.array_type(node)
  local len = 0
  local domain = node:domain()
  if domain then
    len = node:domain():max():value() + 1
  end
  emitter:add(string.format('[%d]', len))
  visit(node:type())
end

function nldecl.function_type(node)
  emitter:add('function(')
  local i = 1
  for argnode in chain(node:args()) do
    local argtype = argnode:value()
    if argtype:code() == 'void_type' then
      break
    end
    if i > 1 then emitter:add(', ') end
    visit(argnode:value())
    i = i + 1
  end
  if gccutils.has_cvarargs(node) then
    emitter:add(', ...: cvarargs')
  end
  emitter:add(')')
  local retnode = node:type()
  if retnode:code() ~= 'void_type' then
    emitter:add(': ')
    visit(retnode)
  end
end

function nldecl.function_decl(node)
  emitter.in_function_decl = true
  local funcname = node:name():value()
  if not nldecl.can_decl(funcname) then return end
  nldecl.declared_names[funcname] = true
  emitter:add('global function ')
  emitter:add(funcname)
  emitter:add('(')
  local i = 1
  for argnode in chain(node:args()) do
    local argtype = argnode:type()
    if argtype:code() == 'void_type' then
      break
    end
    if i > 1 then emitter:add(', ') end
    local argname = gccutils.get_id(argnode)
    if not argname then
      argname = 'a'..i
    end
    argname = gccutils.normalize_name(argname)
    emitter:add(argname)
    emitter:add(': ')
    visit(argtype)
    i = i + 1
  end
  if gccutils.has_cvarargs(node:type()) then
    emitter:add(', ...: cvarargs')
  end
  emitter:add(')')
  local retnode = node:type():type()
  if retnode:code() ~= 'void_type' then
    emitter:add(': ')
    visit(retnode)
  end
  emitter:add_ln(' <cimport, nodecl> end')
  emitter.in_function_decl = nil
end

function nldecl.var_decl(node)
  local varname = gccutils.get_id(node)
  if not nldecl.can_decl(varname) then return end
  nldecl.declared_names[varname] = true
  local vartype = node:type()
  emitter:add('global ')
  emitter:add(varname)
  emitter:add(': ')
  visit(vartype)
  emitter:add_ln(' <cimport, nodecl>')
end

local function visit_type_decl(typename, type)
  local forwarddecl = (type:code() == 'record_type' or type:code() == 'union_type') and
                      not type:fields()
  if not nldecl.can_decl(typename, forwarddecl) then return end
  emitter:add('global ')
  emitter:add(typename)
  if forwarddecl then -- declaration without definition
    emitter:add(': type <cimport, forwarddecl> = @')
    nldecl.predeclared_names[typename] = true
  else
    emitter:add(': type <cimport, nodecl> = @')
    nldecl.declared_names[typename] = true
  end
  visit(type, true)
  emitter:add_ln()
end

function nldecl.type_decl(node)
  local typename = node:name():value()
  local type = node:type()
  local kind = type:code()
  if (kind == 'void_type' or
      kind == 'integer_type' or
      kind == 'real_type' or
      kind == 'array_type') and
     (not nldecl.include_names[typename]) then
    return
  end
  assert(typename and #typename > 0)
  visit_type_decl(typename, type)
end

function nldecl.parm_decl()
  -- ignored, already processed in function_decl
end

function nldecl.field_decl()
  -- ignored, already processed in record_type/union_type
end

function nldecl.install()
  gcc.set_asm_file_name(gcc.HOST_BIT_BUCKET)
  gcc.register_callback(gcc.PLUGIN_FINISH_DECL, function(node)
    visit(node, nldecl.emitter)
  end)
  gcc.register_callback(gcc.PLUGIN_FINISH_TYPE, function(node)
    local typename = gccutils.get_id(node)
    if typename then
      visit_type_decl(typename, node)
    end
  end)
  gcc.register_callback(gcc.PLUGIN_START_UNIT, function()
    if nldecl.prepend_code then
      emitter:add(nldecl.prepend_code)
    end
  end)
  gcc.register_callback(gcc.PLUGIN_FINISH_UNIT, function()
    if nldecl.append_code then
      emitter:add(nldecl.append_code)
    end
    if nldecl.on_finish then
      nldecl.on_finish()
    else
      io.stdout:write(emitter:generate())
      io.stdout:flush()
    end
  end)
end

nldecl.install()

return nldecl
