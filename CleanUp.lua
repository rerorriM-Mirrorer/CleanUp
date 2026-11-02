-- CleanUp beta 1: inventory policy and observed, one-at-a-time transfers.
-- Derived from the idea of MogMover; this is a separate addon and does not edit MogMover.
_addon.name = 'CleanUp'
_addon.author = 'A + ChatGPT; MogMover concept by Kaius @Bahamut'
_addon.version = '0.1.1-beta1'
_addon.commands = {'cu', 'cleanup'}

local config = require('config')
local res = require('resources')
require('chat') -- Windower's string.color() for BattleStations-style chat formatting.

local defaults = {
    cleanupmode = false, -- never begin automatic dumping on a fresh install
    dumpbag = 'case',
    delay = 2, -- seconds between confirmed/attempted transfers
    homes = {}, -- item ID -> satchel/sack/case
    inventory = {}, -- item ID -> quantity or 'all'; inventory override layer
    debug = false,
}
local settings = config.load(defaults)
local bags = {inventory=0, satchel=5, sack=6, case=7}
local bag_order = {'satchel', 'sack', 'case'}
local aliases = {['mog satchel']='satchel', ['mog sack']='sack', ['mog case']='case'}
local temporary = {} -- same inventory override layer, session-only, from //cu get
local pending = nil
local blocked = {} -- temporarily back off a transfer that did not complete
local manual = nil -- nil, 'all', or item ID; one manual pass when cleanup mode is off
local last_attempt = 0
local last_scan = -1
local alerts = {}

-- Shared chat-only presentation: BattleStations-style colored fragments.
-- Windower add_to_chat mode 0 leaves embedded string.color() controls intact.
local function color(value, code)
    return string.color(tostring(value), code)
end
local function emit(line)
    windower.add_to_chat(0, line)
end
local function say(message)
    emit(color('//cu', 200)..color(' -> ', 200)..color(message, 0))
end
local function debug(message)
    if settings.debug then say(color('Debug', 167)..': '..message) end
end
local function help_divider()
    emit(color(string.rep('-', 48), 140))
end
local function help_heading(title)
    emit(color('  '..title, 167))
end
local function help_line(syntax, description)
    local leader, rest = syntax:match('^(//cu)(.*)$')
    emit('  '..color(leader or '//cu', 200)..color(rest or '', 207)
        ..' '..color('->', 200)..' '..color(description, 0))
end
local function show_help()
    help_divider()
    help_heading('CleanUp  '.._addon.version..'  |  Commands')
    help_divider()
    help_heading('Inventory rules')
    help_line('//cu <item> <satchel|sack|case>', 'Assign item home')
    help_line('//cu <item> inventory [amount]', 'Keep all or a quantity in inventory')
    help_line('//cu clear <item> <home|inventory|all>', 'Remove an item rule')
    help_heading('Cleanup')
    help_line('//cu preview', 'Preview moves without changing inventory')
    help_line('//cu cleanupmode <on|off>', 'Enable/disable automatic cleanup')
    help_line('//cu dump <case|satchel|sack>', 'Choose default home for unassigned items')
    help_line('//cu tidy', 'Run one manual cleanup pass')
    help_line('//cu delay [seconds]', 'Show/set transfer delay (1-30)')
    help_heading('Temporary inventory overrides')
    help_line('//cu get <item> [amount]', 'Retrieve a temporary inventory reserve')
    help_line('//cu release <item>', 'Release a temporary reserve')
    help_heading('Information and lifecycle')
    help_line('//cu status', 'Current mode, dump bag, and rule counts')
    help_line('//cu list', 'Show item home and inventory overrides')
    help_line('//cu debug <on|off>', 'Show or hide transfer diagnostics')
    help_line('//cu help', 'Display this command list')
    help_line('//cu restart', 'Restart CleanUp')
    help_line('//cu unload', 'Unload CleanUp')
    help_divider()
end
local function clean_name(s)
    s = tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if (s:sub(1,1)=='"' and s:sub(-1)=='"') or
       (s:sub(1,1)=="'" and s:sub(-1)=="'") then s=s:sub(2,-2) end
    return s
end
local function bag_name(s)
    s=clean_name(s):lower()
    return aliases[s] or s
end
local function safe()
    local info=windower.ffxi.get_info()
    if not info or not info.logged_in then return false end
    local player=windower.ffxi.get_player()
    -- Do not move items during combat, death, events or cutscenes.
    if not player or player.status ~= 0 then return false end
    if info.menu_open then return false end
    return true
end
local function bag_ready(name)
    local id=bags[name]
    if id==nil then return false end
    local info=windower.ffxi.get_bag_info(id)
    return info and info.enabled and info.max and info.count and info.max>info.count
end
local function read_bag(id)
    return windower.ffxi.get_items(id) or {}
end
local function total(id, itemid)
    local n=0
    for _,item in pairs(read_bag(id)) do
        if type(item)=='table' and item.id==itemid then
            n=n+(tonumber(item.count) or 0)
        end
    end
    return n
end
local function stacks(id, itemid)
    local out={}
    for slot,item in pairs(read_bag(id)) do
        if type(slot)=='number' and type(item)=='table' and item.id==itemid and
           (item.count or 0)>0 and item.status==0 then
            out[#out+1]={slot=slot, count=item.count}
        end
    end
    table.sort(out,function(a,b) return a.slot<b.slot end)
    return out
end
local function bag_display(id)
    return ({[0]='inventory',[5]='satchel',[6]='sack',[7]='case'})[id] or tostring(id)
end
local function label(itemid)
    local item=res.items[tonumber(itemid)]
    return item and (item.en or item.name or item.english) or ('Item # '..tostring(itemid))
end
local function find_id(name)
    name=clean_name(name)
    if name=='' then return nil end
    local number=tonumber(name)
    if number and res.items[number] then return number end
    for id,item in pairs(res.items) do
        if type(id)=='number' and type(item)=='table' then
            for _,field in ipairs({'en','name','name_log','english','english_log'}) do
                if type(item[field])=='string' and item[field]:lower()==name:lower() then
                    return id
                end
            end
        end
    end
    return nil
end
local function store()
    settings:save('all')
end
local function reserve(id)
    local saved=settings.inventory[tostring(id)]
    if saved=='all' then return 'all' end
    local count=tonumber(saved) or 0
    return math.max(0,count,temporary[tostring(id)] or 0)
end
local function destination(id)
    local home=bag_name(settings.homes[tostring(id)] or '')
    if bags[home] and home~='inventory' then return home end
    return bag_name(settings.dumpbag)
end
local function action_key(a)
    return table.concat({a.itemid,a.source,a.dest}, ':')
end
local function add_action(out, itemid, source, dest, slot, count, reason)
    out[#out+1]={itemid=itemid,source=source,dest=dest,slot=slot,count=count,reason=reason}
end

-- Compute the desired state from current inventory, not a stale queue.
-- Pull reserved food first; stow excess after. Only touch Inventory/Satchel/Sack/Case.
local function plan(filter)
    local actions, notices={},{}
    local known={}
    for id,value in pairs(settings.inventory) do if value~=nil then known[tonumber(id)]=true end end
    for id in pairs(temporary) do known[tonumber(id)]=true end
    for id in pairs(settings.homes) do known[tonumber(id)]=true end
    for _,item in pairs(read_bag(0)) do
        if type(item)=='table' and item.id and item.id>0 then known[item.id]=true end
    end
    local ids={}
    for id in pairs(known) do
        if id and (filter==nil or filter==id) then ids[#ids+1]=id end
    end
    table.sort(ids)

    -- Reserve pulls always have priority over clearing inventory.
    for _,id in ipairs(ids) do
        local desired=reserve(id)
        -- An 'all' override preserves everything already here, while an explicit
        -- temporary //cu get can still request more from storage.
        local retrieve=desired=='all' and (temporary[tostring(id)] or 0) or desired
        if type(retrieve)=='number' and retrieve>total(0,id) then
            local needed=retrieve-total(0,id)
            if not bag_ready('inventory') then
                notices[#notices+1]='Inventory unavailable/full: cannot retrieve '..label(id)
            else
                local order={destination(id)}
                for _,other in ipairs(bag_order) do
                    if other~=order[1] then order[#order+1]=other end
                end
                for _,home in ipairs(order) do
                    if needed<=0 then break end
                    if bags[home] and home~='inventory' then
                        local info=windower.ffxi.get_bag_info(bags[home])
                        if info and info.enabled then
                            for _,stack in ipairs(stacks(bags[home],id)) do
                                if needed<=0 then break end
                                local count=math.min(needed,stack.count)
                                add_action(actions,id,bags[home],0,stack.slot,count,'reserve')
                                needed=needed-count
                            end
                        end
                    end
                end
            end
        end
    end
    for _,id in ipairs(ids) do
        local desired=reserve(id)
        if desired~='all' then
            local surplus=total(0,id)-desired
            if surplus>0 then
                local dest=destination(id)
                if not bag_ready(dest) then
                    notices[#notices+1]=dest..' unavailable/full: '..label(id)..' remains in inventory'
                else
                    for _,stack in ipairs(stacks(0,id)) do
                        if surplus<=0 then break end
                        local count=math.min(surplus,stack.count)
                        add_action(actions,id,0,bags[dest],stack.slot,count,'home')
                        surplus=surplus-count
                    end
                end
            end
        end
    end
    return actions,notices
end
local function report_plan()
    if not safe() then say('Preview unavailable while the character is busy or not logged in.') return end
    local actions,notices=plan(nil)
    help_divider()
    help_heading(('CleanUp Preview  |  %d transfer(s), dump: %s'):format(#actions, settings.dumpbag))
    help_divider()
    say('Preview only. No items moved.')
    local max=15
    for i,a in ipairs(actions) do
        if i>max then break end
        local src=(a.source==0 and 'inventory' or ({[5]='satchel',[6]='sack',[7]='case'})[a.source])
        local dst=(a.dest==0 and 'inventory' or ({[5]='satchel',[6]='sack',[7]='case'})[a.dest])
        emit('  '..color(label(a.itemid)..' x'..a.count,207)..'  '..color(src,0)..' '..color('->',200)..' '..color(dst,0)..' ('..a.reason..')')
    end
    if #actions>max then say(('  ...and %d more transfer(s)'):format(#actions-max)) end
    for i=1,math.min(#notices,5) do say('Skipped: '..notices[i]) end
    help_divider()
end
local function reset_run()
    pending=nil
    blocked={}
    manual=nil
    last_scan=-1
end
local function settle_pending(now)
    local a=pending
    if not a then return false end
    local from=total(a.source,a.itemid)
    local to=total(a.dest,a.itemid)
    if from<a.before_source and to>a.before_dest then
        say(('Moved %s x%d: %s -> %s.'):format(label(a.itemid),math.min(a.count,a.before_source-from),
            bag_display(a.source), bag_display(a.dest)))
        pending=nil
        return false
    end
    if now-a.started>=10 then
        local key=action_key(a)
        blocked[key]=now+60
        say(('Transfer not confirmed for %s; pausing this route for 60s.'):format(label(a.itemid)))
        pending=nil
        return false
    end
    return true
end
local function issue(a,now)
    local before_source=total(a.source,a.itemid)
    local before_dest=total(a.dest,a.itemid)
    if before_source<a.count then return false end
    debug(('Requesting %s x%d from %d to %d, slot %d'):format(label(a.itemid),a.count,a.source,a.dest,a.slot))
    local ok,err=pcall(windower.ffxi.move_item,a.source,a.dest,a.slot,a.count)
    last_attempt=now
    if not ok then
        blocked[action_key(a)]=now+60
        say(('Transfer request failed for %s: %s'):format(label(a.itemid),tostring(err)))
        return false
    end
    a.before_source=before_source
    a.before_dest=before_dest
    a.started=now
    pending=a
    return true
end
local function tick()
    local now=os.time()
    if now==last_scan then return end
    last_scan=now
    if not safe() then return end
    if settle_pending(now) then return end
    if not settings.cleanupmode and not manual then return end
    if now-last_attempt<math.max(1,tonumber(settings.delay) or 2) then return end
    local actions,notices=plan(type(manual)=='number' and manual or nil)
    for _,a in ipairs(actions) do
        if not blocked[action_key(a)] or blocked[action_key(a)]<=now then
            if issue(a,now) then return end
        end
    end
    if manual then
        if #actions==0 then say('Manual cleanup complete.') else say('Manual cleanup paused: no transfer available.') end
        manual=nil
    end
    if #actions==0 and #notices>0 then
        local note=notices[1]
        if not alerts[note] or now-alerts[note]>=120 then
            say('Paused: '..note)
            alerts[note]=now
        end
    end
end
local function show_status()
    local h,n=0,0
    for _ in pairs(settings.homes) do h=h+1 end
    for _ in pairs(settings.inventory) do n=n+1 end
    help_divider()
    help_heading('CleanUp Status')
    help_divider()
    say(('Mode: %s; dump: %s; homes: %d; inventory overrides: %d; delay: %ss.'):
        format(settings.cleanupmode and 'ON' or 'OFF',settings.dumpbag,h,n,tostring(settings.delay)))
    if pending then say('Waiting for transfer confirmation: '..label(pending.itemid)) end
    if manual then say('Manual operation active.') end
end
local function list_rules()
    local ids={}
    for id in pairs(settings.homes) do ids[id]=true end
    for id in pairs(settings.inventory) do ids[id]=true end
    for id in pairs(temporary) do ids[id]=true end
    local ordered={}
    for id in pairs(ids) do ordered[#ordered+1]=id end
    table.sort(ordered,function(a,b) return tonumber(a)<tonumber(b) end)
    if #ordered==0 then say('No item rules configured. Unassigned items go to '..settings.dumpbag..' when cleanup is on.') end
    for _,id in ipairs(ordered) do
        local temp=temporary[id]
        local inv=settings.inventory[id]
        say(('%s: home %s, inventory %s%s'):format(label(id),settings.homes[id] or settings.dumpbag,
            inv==nil and '0' or tostring(inv),temp and ('; temporary reserve '..temp) or ''))
    end
end
local function parse_item(args,last)
    local parts={}
    for i=1,last do parts[#parts+1]=args[i] end
    local name=clean_name(table.concat(parts,' '))
    local id=find_id(name)
    if not id then say('Unknown item: '..name) end
    return id
end
local function set_rule(args)
    local n=#args
    if n<2 then say('Usage: //cu <item> <satchel|sack|case|inventory> [amount]') return end
    local amount=nil
    if tonumber(args[n]) and n>=3 then
        amount=tonumber(args[n]); n=n-1
    end
    local bag=bag_name(args[n])
    if not bags[bag] then say('Unknown destination: '..bag..'. Use inventory, satchel, sack or case.') return end
    if amount and (amount<0 or amount~=math.floor(amount)) then say('Amount must be a non-negative whole number.') return end
    if amount and bag~='inventory' then say('Quantities are only supported for the inventory override.') return end
    local id=parse_item(args,n-1)
    if not id then return end
    if bag=='inventory' then
        settings.inventory[tostring(id)]=amount or 'all'
        temporary[tostring(id)]=nil
        say(('Inventory override for %s: %s.'):format(label(id),amount==nil and 'keep what is here' or tostring(amount)))
    else
        settings.homes[tostring(id)]=bag
        say(('Home for %s: %s (inventory override unchanged).'):format(label(id),bag))
    end
    store()
    blocked={}
end
local function handle(command,...)
    local args={...}
    command=command and command:lower() or 'help'
    if command=='help' or command=='' then
        show_help()
    elseif command=='status' then show_status()
    elseif command=='list' then list_rules()
    elseif command=='preview' then report_plan()
    elseif command=='dump' then
        local name=bag_name(table.concat(args,' '))
        if name=='inventory' or not bags[name] then say('Use //cu dump satchel|sack|case') return end
        settings.dumpbag=name;store();blocked={}
        say('Default dump bag: '..name)
    elseif command=='cleanupmode' then
        local value=table.concat(args,' '):lower()
        if value~='on' and value~='off' then say('Usage: //cu cleanupmode on|off') return end
        settings.cleanupmode=value=='on';store();manual=nil
        if not settings.cleanupmode then pending=nil end -- an issued transfer may still finish server-side
        say('Automatic cleanup '..(settings.cleanupmode and 'ON (unassigned items will go to '..settings.dumpbag..')' or 'OFF (new automatic transfers stopped)'))
    elseif command=='tidy' or command=='apply' then
        manual='all';say('Manual cleanup requested. Use //cu cleanupmode off to stop after current transfer.')
    elseif command=='delay' then
        if #args==0 then say('Transfer delay: '..tostring(settings.delay)..'s') return end
        local sec=tonumber(args[1])
        if not sec or sec<1 or sec>30 then say('Delay must be 1 to 30 seconds.') return end
        settings.delay=sec;store();say('Transfer delay: '..tostring(sec)..'s')
    elseif command=='get' then
        local count=tonumber(args[#args])
        local last=count and #args-1 or #args
        count=count or 1
        if count<1 or count~=math.floor(count) then say('Get amount must be a positive whole number.') return end
        local id=parse_item(args,last)
        if not id then return end
        local key=tostring(id)
        temporary[key]=math.max(temporary[key] or 0,count)
        if not settings.cleanupmode then manual=id end
        blocked={}
        say(('Temporary inventory reserve: %s x%d. //cu release "%s" to end it.'):format(label(id),temporary[key],label(id)))
    elseif command=='release' then
        local id=parse_item(args,#args)
        if not id then return end
        temporary[tostring(id)]=nil
        if type(manual)=='number' and manual==id then manual=nil end
        say('Released temporary reserve for '..label(id)..'.')
    elseif command=='clear' then
        local layer=(args[#args] or ''):lower()
        if layer~='home' and layer~='inventory' and layer~='all' then say('Usage: //cu clear <item> home|inventory|all') return end
        local id=parse_item(args,#args-1)
        if not id then return end
        local key=tostring(id)
        if layer=='home' or layer=='all' then settings.homes[key]=nil end
        if layer=='inventory' or layer=='all' then settings.inventory[key]=nil;temporary[key]=nil end
        store();blocked={};say('Cleared '..layer..' rule for '..label(id)..'.')
    elseif command=='debug' then
        local value=(args[1] or ''):lower()
        if value=='on' or value=='off' then settings.debug=value=='on';store() end
        say('Debug '..(settings.debug and 'ON' or 'OFF'))
    elseif command=='off' then
        settings.cleanupmode=false;store();manual=nil;pending=nil
        say('Automatic cleanup OFF; no new transfers will be started.')
    elseif command=='restart' then
        say('Restarting CleanUp.')
        reset_run()
        windower.send_command('lua r CleanUp')
    elseif command=='unload' then
        say('Unloading CleanUp.')
        reset_run()
        windower.send_command('lua u CleanUp')
    else
        -- The short form is //cu <item> <bag> [inventory amount].
        -- Unknown commands must show help rather than being mistaken for items.
        local trailing = bag_name(args[#args] or '')
        if tonumber(args[#args]) and #args >= 2 then
            trailing = bag_name(args[#args-1] or '')
        end
        if #args >= 1 and bags[trailing] then
            table.insert(args,1,command)
            set_rule(args)
        else
            say('Unknown command: '..command)
            show_help()
        end
    end
end

windower.register_event('addon command',handle)
windower.register_event('prerender',tick)
windower.register_event('zone change',function() reset_run() end)
windower.register_event('logout',function() reset_run() end)
windower.register_event('unload',function() reset_run() end)
windower.register_event('login',function()
    reset_run()
    say('Loaded. Cleanup '..(settings.cleanupmode and 'ON' or 'OFF')..'. Use //cu preview before enabling.')
end)
