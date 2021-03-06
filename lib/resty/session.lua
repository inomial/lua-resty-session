local require      = require
local var          = ngx.var
local header       = ngx.header
local concat       = table.concat
local hmac         = ngx.hmac_sha1
local time         = ngx.time
local http_time    = ngx.http_time
local set_header   = ngx.req.set_header
local clear_header = ngx.req.clear_header
local ceil         = math.ceil
local max          = math.max
local find         = string.find
local gsub         = string.gsub
local sub          = string.sub
local type         = type
local pcall        = pcall
local tonumber     = tonumber
local setmetatable = setmetatable
local getmetatable = getmetatable
local random       = require "resty.random".bytes

local function enabled(val)
    if val == nil then return nil end
    return val == true or (val == "1" or val == "true" or val == "on")
end

local function ifnil(value, default)
    if value == nil then
        return default
    end
    return enabled(value)
end

local function prequire(prefix, package, default)
    local o, p = pcall(require, prefix .. package)
    if not o then
        return require(prefix .. default), default
    end
    return p, package
end

local function setcookie(session, value, expires)
    if session.basic then
        return true
    end

    if ngx.headers_sent then return nil, "Attempt to set session cookie after sending out response headers." end
    local c = session.cookie
    local i = 3
    local k = {}
    local d = c.domain
    local x = c.samesite
    if expires then
        k[i] = "; Expires=Thu, 01 Jan 1970 00:00:01 GMT; Max-Age=0"
        i=i+1
    elseif c.persistent then
        k[i]   = "; Expires="
        k[i+1] = http_time(session.expires)
        k[i+2] = "; Max-Age="
        k[i+3] = c.lifetime
        i=i+4
    end
    if d and d ~= "localhost" and d ~= "" then
        k[i]   = "; Domain="
        k[i+1] = d
        i=i+2
    end
    k[i]   = "; Path="
    k[i+1] = c.path or "/"
    i=i+2
    if x == "Lax" or x == "Strict" then
        k[i] = "; SameSite="
        k[i+1] = x
        i=i+2
    end
    if c.secure then
        k[i] = "; Secure"
        i=i+1
    end
    if c.httponly then
        k[i] = "; HttpOnly"
    end
    local v = value or ""
    local l
    if expires and c.chunks then
        l = c.chunks
    else
        l = max(ceil(#v / 4000), 1)
    end
    local s = header["Set-Cookie"]
    for j=1, l do
        local n = { session.name }
        if j > 1 then
            n[2] = "_"
            n[3] = j
            n[4] = "="
        else
            n[2] = "="
        end
        local n = concat(n)
        k[1] = n
        if expires then
            k[2] = ""
        else
            local sp = j * 4000 - 3999
            if j < l then
                k[2] = sub(v, sp, sp + 3999) .. "0"
            else
                k[2] = sub(v, sp)
            end
        end
        local y = concat(k)
        local t = type(s)
        if t == "table" then
            local f = false
            local z = #s
            for i=1, z do
                if find(s[i], n, 1, true) == 1 then
                    s[i] = y
                    f = true
                    break
                end
            end
            if not f then
                s[z+1] = y
            end
        elseif t == "string" and find(s, n, 1, true) ~= 1  then
            s = { s, y }
        else
            s = y
        end
    end
    header["Set-Cookie"] = s
    return true
end

local function isEmpty(s)
    return s == nil or s == ''
end

local function getbasic(session)
    -- extract the session credentials from basic authorization header
    local user, pass = var.remote_user, var.remote_passwd
    if isEmpty(user) or isEmpty(pass) then
        return
    end

    ngx.log(ngx.DEBUG, "basic credentials, user: ", user, " password: ", pass)
    ngx.log(ngx.DEBUG, "session.cookie.lifetime = ", session.cookie.lifetime)

    return session.encoder.encode(user) .. "|" .. time() + session.cookie.lifetime .. "|" .. (session.raw_hmac == true and session.encoder.encode(pass) or pass)
end

local function getcookie(session, i)
    local name = session.name
    local n = { "cookie_", name }
    if i then
        n[3] = "_"
        n[4] = i
    else
        i = 1
    end
    session.cookie.chunks = i
    local c = var[concat(n)]
    if not c then return nil end
    local l = #c
    if l < 4001 then return c end
    return concat{ sub(c, 1, 4000), getcookie(session, i + 1) or "" }
end

local function getdkey(d)
    local dkey
    if type(d) == "table" and d.id_token ~= nil and not isEmpty(d.id_token.sub) then
        dkey = concat{d.id_token.sub, d.id_token.auth_time}
        ngx.log(ngx.DEBUG, "using dkey instead of d for hmac message: ", dkey)
    end
    return dkey
end

local function gethmackey(d)
    local hmackey
    if type(d) == "table" and not isEmpty(d.hmackey) then
        hmackey = d.hmackey
        ngx.log(ngx.DEBUG, "using hmackey from session data instead of k, hmackey: ", hmackey)
    end
    return hmackey
end

local function save(session, close)
    session.expires = time() + session.cookie.lifetime
    local i, e, s = session.id, session.expires, session.storage
    local k = hmac(session.secret, i)
    if session.basic and session.check.hmac == true and isEmpty(session.data.hmackey) then
        -- assign a random hmac key by default only when in basic auth mode
        session.data.hmackey = ngx.encode_base64(require('resty.session.identifiers.random')({}))
        ngx.log(ngx.DEBUG, "setting random hmackey: ", session.data.hmackey)
    end
    local d = session.serializer.serialize(session.data)
    local h = hmac(gethmackey(session.data) or k, concat{ i, getdkey(session.data) or d, session.key })
    session.hmac = h
    local cryptkey
    if session.check.hmac == false and session.raw_hmac == true and session.basic then
        cryptkey = hmac(k, ngx.var.remote_passwd)
    else
        cryptkey = hmac(k, h)
    end
    ngx.log(ngx.DEBUG, "session.secret = ", session.secret)
    ngx.log(ngx.DEBUG, "i = ", ngx.encode_base64(i))
    ngx.log(ngx.DEBUG, "e = ", e, " session.cookie.lifetime = ", session.cookie.lifetime)
    ngx.log(ngx.DEBUG, "d = ", ngx.encode_base64(d))
    ngx.log(ngx.DEBUG, "h = ", ngx.encode_base64(h))
    ngx.log(ngx.DEBUG, "k = ", ngx.encode_base64(k))
    ngx.log(ngx.DEBUG, "cryptkey = " .. ngx.encode_base64(cryptkey))
    if session.data.id_token and not isEmpty(session.data.id_token.sub) then
        s.subkey = "sub:" .. session.redis.prefix .. ":" .. session.encoder.encode(session.data.id_token.sub)
    end
    local d = session.cipher:encrypt(d, cryptkey, i, session.key)
    local cookie, err = s:save(i, e, d, h, close)
    if cookie then
        return setcookie(session, cookie)
    end
    return nil, err
end

local function regenerate(session, flush)
    if session.basic then
        return true
    end

    local i = session.present and session.id
    session.id = session:identifier()
    if flush then
        if i and session.storage.destroy then
            session.storage:destroy(i)
        end
        session.data = {}
    end
end

local secret = random(32, true) or random(32)
local defaults

local function init()
    defaults = {
        name       = var.session_name       or "session",
        identifier = var.session_identifier or "random",
        storage    = var.session_storage    or "redis",
        serializer = var.session_serializer or "json",
        encoder    = var.session_encoder    or "base64",
        cipher     = var.session_cipher     or "aes",
        cookie = {
            persistent = enabled(var.session_cookie_persistent or false),
            renew      = tonumber(var.session_cookie_renew)    or 600,
            lifetime   = tonumber(var.session_cookie_lifetime) or 3600,
            path       = var.session_cookie_path               or "/",
            domain     = var.session_cookie_domain,
            samesite   = var.session_cookie_samesite           or "Lax",
            secure     = enabled(var.session_cookie_secure),
            httponly   = enabled(var.session_cookie_httponly   or true),
            delimiter  = var.session_cookie_delimiter          or "|"
        }, check = {
            ssi    = enabled(var.session_check_ssi    or false),
            ua     = enabled(var.session_check_ua     or true),
            scheme = enabled(var.session_check_scheme or true),
            addr   = enabled(var.session_check_addr   or false),
            hmac   = enabled(var.session_check_hmac   or true)
        }
    }
    defaults.secret = var.session_secret or secret
end

local session = {
    _VERSION = "2.19"
}

session.__index = session

function session.new(opts)
    if getmetatable(opts) == session then
        return opts
    end
    if not defaults then
        init()
    end
    local z = defaults
    local y = type(opts) == "table" and opts or z
    local a, b = y.cookie or z.cookie, z.cookie
    local c, d = y.check  or z.check,  z.check
    local e, f = prequire("resty.session.identifiers.", y.identifier or z.identifier, "random")
    local g, h = prequire("resty.session.serializers.", y.serializer or z.serializer, "json")
    local i, j = prequire("resty.session.encoders.",    y.encoder    or z.encoder,    "base64")
    local k, l = prequire("resty.session.ciphers.",     y.cipher     or z.cipher,     "aes")
    local m, n = prequire("resty.session.storage.",     y.storage    or z.storage,    "redis")
    local self = {
        basic      = ifnil(y.basic, false),
        raw_hmac   = ifnil(y.raw_hmac, false),
        name       = y.name   or z.name,
        identifier = e,
        serializer = g,
        encoder    = i,
        data       = y.data   or {},
        secret     = y.secret or z.secret,
        cookie = {
            persistent = ifnil(a.persistent, b.persistent),
            renew      = a.renew          or b.renew,
            lifetime   = a.lifetime       or b.lifetime,
            path       = a.path           or b.path,
            domain     = a.domain         or b.domain,
            samesite   = a.samesite       or b.samesite,
            secure     = ifnil(a.secure,     b.secure),
            httponly   = ifnil(a.httponly,   b.httponly),
            delimiter  = a.delimiter      or b.delimiter
        }, check = {
            ssi        = ifnil(c.ssi,        d.ssi),
            ua         = ifnil(c.ua,         d.ua),
            scheme     = ifnil(c.scheme,     d.scheme),
            addr       = ifnil(c.addr,       d.addr),
            hmac       = ifnil(c.hmac,       d.hmac)
        }
    }
    if y[f] and not self[f] then self[f] = y[f] end
    if y[h] and not self[h] then self[h] = y[h] end
    if y[j] and not self[j] then self[j] = y[j] end
    if y[l] and not self[l] then self[l] = y[l] end
    if y[n] and not self[n] then self[n] = y[n] end
    self.ciphertype = l
    self.cipher  = k.new(self)
    self.storage = m.new(self)
    return setmetatable(self, session)
end

function session.open(opts)
    local self = opts
    if getmetatable(self) == session then
        if self.opened then
            return self, self.present
        end
    else
        self = session.new(opts)
    end
    local scheme = header["X-Forwarded-Proto"]
    if self.cookie.secure == nil then
        if scheme then
            self.cookie.secure = scheme == "https"
        else
            self.cookie.secure = var.https == "on"
        end
    end
    scheme = self.check.scheme and (scheme or var.scheme or "") or ""
    local addr = ""
    if self.check.addr then
        addr = header["CF-Connecting-IP"] or
               header["Fastly-Client-IP"] or
               header["Incap-Client-IP"]  or
               header["X-Real-IP"]
        if not addr then
            addr = header["X-Forwarded-For"]
            if addr then
                -- We shouldn't really get the left-most address, because of spoofing,
                -- but this is better handled with a module, like nginx realip module,
                -- anyway (see also: http://goo.gl/Z6u2oR).
                local s = find(addr, ',', 1, true)
                if s then
                    addr = addr:sub(1, s - 1)
                end
            else
                addr = var.remote_addr
            end
        end
    end
    self.key = concat{
        self.check.ssi and (var.ssl_session_id  or "") or "",
        self.check.ua  and (var.http_user_agent or "") or "",
        addr,
        scheme
    }
    self.opened = true
    -- require aes storage cipher when self.check.hmac is false (otherwise there is nothing left to validate the session)
    if self.check.hmac == false and self.ciphertype ~= "aes" then
        ngx.log(ngx.ERR, "aes cipher required when check.hmac is disabled, the cipher is: ", self.ciphertype)
        return self, false
    end
    local cookie
    if self.basic then
        cookie = getbasic(self)
    else
        cookie = getcookie(self)
    end
    if cookie then
        ngx.log(ngx.DEBUG, "cookie present: ", cookie)
        local i, e, d, h = self.storage:open(cookie, self.cookie.lifetime)
        if i and tonumber(e) and d and h then
            ngx.log(ngx.DEBUG, "cookie session data retrieved")
            ngx.log(ngx.DEBUG, "i: " .. ngx.encode_base64(i))
            ngx.log(ngx.DEBUG, "e: " .. e .. " (time: " .. time() .. ")")
            ngx.log(ngx.DEBUG, "d: " .. ngx.encode_base64(d))
            ngx.log(ngx.DEBUG, "h: " .. ngx.encode_base64(h))
            local k = hmac(self.secret, i)
            ngx.log(ngx.DEBUG, "k: " .. ngx.encode_base64(k))
            local cryptkey = hmac(k, h)
            ngx.log(ngx.DEBUG, "cryptkey: " .. ngx.encode_base64(cryptkey))
            d = self.cipher:decrypt(d, cryptkey, i, self.key)
            local dkey, ds = nil, d
            if d then
                ngx.log(ngx.DEBUG, "d decrypted: " .. d)
                d = self.serializer.deserialize(d)
            else
                ngx.log(ngx.DEBUG, "decryption failed")
            end
            if ds and (self.check.hmac == false or hmac(gethmackey(d) or k, concat{ i, getdkey(d) or ds, self.key }) == h) then
                self.id = i
                self.expires = e
                self.data = type(d) == "table" and d or {}
                self.present = true
                return self, true
            elseif d then
                ngx.log(ngx.DEBUG, "hmac validation failed")
            end
        end
    end
    ngx.log(ngx.DEBUG, "no cookie or invalid session, regenerating and flushing session")
    regenerate(self, true)
    return self, false
end

function session.start(opts)
    if getmetatable(opts) == session and opts.started then
        return opts, opts.present
    end
    local self, present = session.open(opts)

    -- force self.storage:start to be called when in basic auth mode to trigger locking
    if self.basic then
        self.expires = time() + self.cookie.lifetime
        present = true
    end

    if present then
        if self.storage.start then
            local ok, err = self.storage:start(self.id)
            if not ok then return nil, err end
        end
        local now = time()
        if self.expires - now < self.cookie.renew or
           self.expires > now + self.cookie.lifetime then
            local ok, err = save(self)
            if not ok then return nil, err end
        end
    else
        local ok, err = save(self)
        if not ok then return nil, err end
    end
    self.started = true
    return self, present
end

function session:regenerate(flush)
    regenerate(self, flush)
    return save(self)
end

function session:save(close)
    if not self.id then
        self.id = self:identifier()
    end
    return save(self, close ~= false)
end

function session:destroy()
    if self.storage.destroy then
        if self.data.id_token and not isEmpty(self.data.id_token.sub) then
            self.storage.subkey = "sub:" .. self.redis.prefix .. ":" .. self.encoder.encode(self.data.id_token.sub)
        end
        self.storage:destroy(self.id)
    end
    self.data      = {}
    self.present   = nil
    self.opened    = nil
    self.started   = nil
    self.destroyed = true
    return setcookie(self, "", true)
end

function session:hide()
    if session.basic then
        return true
    end

    local cookies = var.http_cookie
    if not cookies then
        return
    end
    local r = {}
    local n = self.name
    local i = 1
    local j = 0
    local s = find(cookies, ";", 1, true)
    while s do
        local c = sub(cookies, i, s - 1)
        local b = find(c, "=", 1, true)
        if b then
            local key = gsub(sub(c, 1, b - 1), "^%s+", "")
            if key ~= n and key ~= "" then
                local z = #n
                if sub(key, z + 1, z + 1) ~= "_" or not tonumber(sub(key, z + 2)) then
                    j = j + 1
                    r[j] = c
                end
            end
        end
        i = s + 1
        s = find(cookies, ";", i, true)
    end
    local c = sub(cookies, i)
    if c and c ~= "" then
        local b = find(c, "=", 1, true)
        if b then
            local key = gsub(sub(c, 1, b - 1), "^%s+", "")
            if key ~= n and key ~= "" then
                local z = #n
                if sub(key, z + 1, z + 1) ~= "_" or not tonumber(sub(key, z + 2)) then
                    j = j + 1
                    r[j] = c
                end
            end
        end
    end
    if j == 0 then
        clear_header("Cookie")
    else
        set_header("Cookie", concat(r, "; ", 1, j))
    end
end

return session
