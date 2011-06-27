description = [[
http-default-accounts tests for access with default credentials in a variety of web applications and devices.

This script depends on a fingerprint file containing the target's information: name, category, location paths, default credentials and login routine.
http-default-accounts searches the paths and if a page is found, it launches the corresponding login routine to check if the default login credentials are valid.

You may select a category if you wish to reduce the number of requests. We have categories like:
* <code>web</code> - Web applications
* <code>router</code> - Routers
* <code>voip</code> - VOIP devices

Please help improve this script by adding new entries to nselib/data/http-default-accounts.lua

Remember each fingerprint must have:
* <code>name</code> - Descriptive name
* <code>category</code> - Category
* <code>login_combos</code> - Table of login combinations
* <code>paths</code> - Paths table containing the possible location of the target
* <code>login_check</code> - Login function of the target

Default fingerprint file: /nselib/data/http-default-accounts-fingerprints.lua 
This script was based on http-enum. 
]]

---
-- @usage
-- nmap -p80 --script http-default-accounts host/ip
-- @output
-- PORT   STATE SERVICE REASON
-- 80/tcp open  http    syn-ack
-- |_http-default-accounts: [Cacti] credentials found -> admin:admin Path:/cacti/
-- Final times for host: srtt: 94615 rttvar: 71012  to: 378663
--
-- @args http-default-accounts.basepath Base path to append to requests. Default: "/"
-- @args http-default-accounts.fingerprintfile Fingerprint filename. Default:http-default-accounts-fingerprints.lua
-- @args http-default-accounts.category Selects a category of fingerprints to use.
-- 
-- Other useful arguments relevant to this script:
-- http.pipeline Sets max number of petitions in the same request.
-- http.useragent User agent for HTTP requests
---

author = "Paulino Calderon"
license = "Same as Nmap--See http://nmap.org/book/man-legal.html"
categories = {"discovery", "auth", "safe"}

require "http"
require "shortport"
portrule = shortport.http

---
--validate_fingerprints(fingerprints)
--Returns an error string if there is something wrong with 
--fingerprint table. 
--Modified's version of http-enums validation code
--@param fingerprints Fingerprint table
--@return Error string if its an invalid fingerprint table
---
local function validate_fingerprints(fingerprints)

  for i, fingerprint in pairs(fingerprints) do
    if(type(i) ~= 'number') then
      return "The 'fingerprints' table is an array, not a table; all indexes should be numeric"
    end
    -- Validate paths
    if(not(fingerprint.paths) or
      (type(fingerprint.paths) ~= 'table' and type(fingerprint.paths) ~= 'string') or
      (type(fingerprint.paths) == 'table' and #fingerprint.paths == 0)) then
      return "Invalid path found in fingerprint entry #" .. i
    end
    if(type(fingerprint.paths) == 'string') then
      fingerprint.paths = {fingerprint.paths}
    end
    for i, path in pairs(fingerprint.paths) do
      -- Validate index
      if(type(i) ~= 'number') then
        return "The 'paths' table is an array, not a table; all indexes should be numeric"
      end
      -- Convert the path to a table if it's a string
      if(type(path) == 'string') then
        fingerprint.paths[i] = {path=fingerprint.paths[i]}
        path = fingerprint.paths[i]
      end
      -- Make sure the paths table has a 'path'
      if(not(path['path'])) then
        return "The 'paths' table requires each element to have a 'path'."
      end
    end
    -- Check login combos
    for i, combo in pairs(fingerprint.login_combos) do
      -- Validate index
      if(type(i) ~= 'number') then
        return "The 'login_combos' table is an array, not a table; all indexes should be numeric"
      end
      -- Make sure the login_combos table has at least one login combo
      if(not(combo['username']) or not(combo["password"])) then
        return "The 'login_combos' table requires each element to have a 'username' and 'password'."
      end
    end

     -- Make sure they include the login function
    if(type(fingerprint.login_check) ~= "function") then
      return "Missing or invalid login_check function in entry #"..i
    end
      -- Are they missing any fields?
    if(fingerprint.category and type(fingerprint.category) ~= "string") then
      return "Missing or invalid category in entry #"..i
    end
    if(fingerprint.name and type(fingerprint.name) ~= "string") then
      return "Missing or invalid name in entry #"..i
    end
  end
end

---
-- load_fingerprints(filename, category)
-- Loads data from file and returns table of fingerprints if sanity checks are passed
-- Based on http-enum's load_fingerprints() 
-- @param filename Fingerprint filename
-- @param cat Category of fingerprints to use
-- @return Table of fingerprints
---
local function load_fingerprints(filename, cat)
  local file, filename_full, fingerprints

  -- Check if fingerprints are cached
  if(nmap.registry.http_default_accounts_fingerprints ~= nil) then
    stdnse.print_debug(1, "%s: Loading cached fingerprints", SCRIPT_NAME)
    return nmap.registry.http_default_accounts_fingerprints
  end

  -- Try and find the file
  -- If it isn't in Nmap's directories, take it as a direct path
  filename_full = nmap.fetchfile('nselib/data/' .. filename)
  if(not(filename_full)) then
    filename_full = filename
  end

  -- Load the file
  stdnse.print_debug(1, "%s: Loading fingerprints: %s", SCRIPT_NAME, filename_full)
  file = loadfile(filename_full)
  if( not(file) ) then
    stdnse.print_debug(1, "%s: Couldn't load the file: %s", SCRIPT_NAME, filename_full)
    return false, "Couldn't load fingerprint file: " .. filename_full
  end
  setfenv(file, setmetatable({fingerprints = {}; }, {__index = _G}))
  file()
  fingerprints = getfenv(file)["fingerprints"]

  -- Validate fingerprints
  local valid_flag = validate_fingerprints(fingerprints)
  if type(valid_flag) == "string" then
    return false, valid_flag
  end

  -- Category filter
  if ( cat ) then
    local filtered_fingerprints = {}
    for _, fingerprint in pairs(fingerprints) do
      if(fingerprint.category == cat) then
        table.insert(filtered_fingerprints, fingerprint)
      end
    end
    fingerprints = filtered_fingerprints
  end

  -- Check there are fingerprints to use
  if(#fingerprints == 0 ) then
    return false, "No fingerprints were loaded after processing ".. filename
  end

  return true, fingerprints
end

---
-- format_basepath(basepath)
-- Removes trailing and leading dashes in a string
-- @param basepath Basepath string
-- @return Basepath string with no trailing or leading dashes
---
local function format_basepath(basepath)
  -- Remove trailing slash, if it exists
  if(#basepath > 1 and string.sub(basepath, #basepath, #basepath) == '/') then
    basepath = string.sub(basepath, 1, #basepath - 1)
  end
  -- Add a leading slash, if it doesn't exist
  if(#basepath <= 1) then
    basepath = ''
  else
    if(string.sub(basepath, 1, 1) ~= '/') then
      basepath = '/' .. basepath
    end
  end
  return basepath  
end

---
-- register_http_credentials(username, password)
-- Stores HTTP credentials in the registry. If the registry entry hasn't been
-- initiated, it will create it and store the credentials.
-- @param login_username Username
-- @param login_password Password
---
local function register_http_credentials(login_username, login_password) 
  if ( not( nmap.registry['credentials'] ) ) then
    nmap.registry['credentials'] = {}
  end
  if ( not( nmap.registry.credentials['http'] ) ) then
    nmap.registry.credentials['http'] = {}
  end
  table.insert( nmap.registry.credentials.http, { username = login_username, password = login_password } )
end

---
-- MAIN
-- Here we iterate through the paths to try to find a target. When a target is found
-- the login routine is initialized to check for default credentials authentication
---
action = function(host, port)
  local fingerprintload_status, fingerprints, requests, results
  local fingerprint_filename = nmap.registry.args["http-default-accounts.fingerprintfile"] or "http-defaul-accounts-fingerprints.lua"
  local category = nmap.registry.args["http-default-accounts.category"] or false
  local basepath = nmap.registry.args["http-default-accounts.basepath"] or "/"
  local output_lns = {}

  --Load fingerprint data or abort 
  status, fingerprints = load_fingerprints(fingerprint_filename, category)
  if(not(status)) then
    return stdnse.format_output(false, fingerprints)
  end
  stdnse.print_debug(1, "%s: %d fingerprints were loaded", SCRIPT_NAME, #fingerprints)

  --Format basepath: Removes or adds slashs
  basepath = format_basepath(basepath)

  -- Add requests to the http pipeline
  requests = {}
  stdnse.print_debug(1, "%s: Searching for entries under path '%s' (change with '%s.basepath' argument)", SCRIPT_NAME, basepath, SCRIPT_NAME)
  for i = 1, #fingerprints, 1 do
    for j = 1, #fingerprints[i].paths, 1 do
      requests = http.pipeline_add(basepath .. fingerprints[i].paths[j].path, nil, requests, 'GET')
    end
  end

  -- Nuclear launch detected!
  results = http.pipeline_go(host, port, requests, nil)
  if results == nil then
    return "[ERROR] HTTP request table is empty. This should not happen since we at least made one request."
  end

  -- Record 404 response, later it will be used to determine if page exists
  local result, result_404, known_404 = http.identify_404(host, port)
  if(result == false) then
    return stdnse.format_output(false, result_404)
  end

  -- Iterate through responses to find a candidate for login routine
  local j = 1
  for i, fingerprint in ipairs(fingerprints) do
    stdnse.print_debug(1, "%s: Processing %s", SCRIPT_NAME, fingerprint.name)
    for _, probe in ipairs(fingerprint.paths) do

      if (results[j]) then
        local path = basepath .. probe['path']

        if( http.page_exists(results[j], result_404, known_404, path, true) ) then
          for _, login_combo in ipairs(fingerprint.login_combos) do
            stdnse.print_debug(2, "%s: Trying login combo -> %s:%s", SCRIPT_NAME, login_combo["username"], login_combo["password"])
            --Check default credentials
            if( fingerprint.login_check(host, port, path, login_combo["username"], login_combo["password"]) ) then
              
              --Valid credentials found
              stdnse.print_debug(1, "%s:[%s] valid default credentials found.", SCRIPT_NAME, fingerprint.name)
              output_lns[#output_lns + 1] = string.format("[%s] credentials found -> %s:%s Path:%s", 
                                          fingerprint.name, login_combo["username"], login_combo["password"], path)
              -- Add to http credentials table
              register_http_credentials(login_combo["username"], login_combo["password"])
            end
          end
        end
      end
      j = j + 1
    end
  end

  if #output_lns > 0 then
    return stdnse.strjoin("\n", output_lns)
  end
end
