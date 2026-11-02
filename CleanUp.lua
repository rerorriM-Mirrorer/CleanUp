-- Beta 2 ring workflow: native Windower equipment operations, live verification pending.
-- CleanUp beta 1: inventory policy and observed, one-at-a-time transfers.
-- Derived from the idea of MogMover; this is a separate addon and does not edit MogMover.
_addon.name = 'CleanUp'
_addon.author = 'A + ChatGPT; MogMover concept by Kaius @Bahamut'
_addon.version = '0.2.0-beta2'
_addon.commands = {'cu', 'cleanup'}

local config = require('config')
local res = require('resources')
local extdata = require('extdata')
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
local ring_job = nil -- independent observed enchantment workflow; blocks general cleanup while active
local ring_bags = {0,5,6,7,8,10,11,12}
local ring_sources = {[0]=true,[5]=true,[6]=true,[7]=true}
local ring_equippable = {[0]=true,[8]=true,[10]=true,[11]=true,[12]=true}
local RING_NAMES = {['echad ring']=true,['warp ring']=true}

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
    help_line('//cu', 'Toggle automatic cleanup ON/OFF')
    help_line('//cu cleanup [on|off]', 'Toggle or explicitly set cleanup')
    help_line('//cu cleanupmode <on|off>', 'Explicit mode command (legacy)')
    help_line('//cu dump <case|satchel|sack>', 'Choose default home for unassigned items')
    help_line('//cu tidy', 'Run one manual cleanup pass')
    help_line('//cu delay [seconds]', 'Show/set transfer delay (1-30)')
    help_heading('Temporary inventory overrides')
    help_line('//cu get <item> [amount]', 'Retrieve a temporary inventory reserve')
    help_line('//cu release <item>', 'Release a temporary reserve')
    help_heading('Enchanted rings (Beta)')
    help_line('//cu ech ring', 'Find, equip and use owned Echad Ring')
    help_line('//cu warp ring', 'Find, equip and use owned Warp Ring')
    help_line('//cu use <item name>', 'Explicit use; currently Echad/Warp Ring only')
    help_line('//cu find <item name>', 'Show closest owned enchantment ring names')
    help_line('//cu recover', 'Restore equipment after an interrupted ring action')
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

-- Superwarp-inspired matching: normalize punctuation/spacing, rank exact/word prefix,
-- then fuzzy similarity. Unlike Superwarp, an item ACTION must pass a minimum
-- confidence AND win by a clear margin, or we do not equip/use anything.
local function norm(s)
    return clean_name(s):lower():gsub('[^%w]', '')
end
local function edit_distance(a,b)
    local previous={}
    for j=0,#b do previous[j]=j end
    for i=1,#a do
        local row={[0]=i}
        for j=1,#b do
            local substitution=(a:sub(i,i)==b:sub(j,j)) and 0 or 1
            row[j]=math.min(previous[j]+1,row[j-1]+1,previous[j-1]+substitution)
        end
        previous=row
    end
    return previous[#b]
end
local function score_name(query, candidate)
    local a,b=norm(query),norm(candidate)
    if a=='' or b=='' then return 0 end
    if a==b then return 1 end
    if b:sub(1,#a)==a then return .94 end
    if b:find(a,1,true) then return .87 end
    local words={}
    for token in candidate:lower():gmatch('[%w]+') do words[#words+1]=token end
    local parts={}
    for token in query:lower():gmatch('[%w]+') do parts[#parts+1]=token end
    if #parts>1 and #parts<=#words then
        local matched=true
        for i,part in ipairs(parts) do
            if words[i]:sub(1,#part)~=part then matched=false;break end
        end
        if matched then return .92 end
    end
    local dist=edit_distance(a,b)
    return math.max(0,1-dist/math.max(#a,#b))*.85
end

local function ring_matches(query)
    local owned={}
    for _,bag in ipairs(ring_bags) do
        local info=windower.ffxi.get_bag_info(bag)
        if info and info.enabled then
            for slot,item in pairs(read_bag(bag)) do
                if type(slot)=='number' and type(item)=='table' and item.id and item.id>0 then
                    local name=label(item.id)
                    if RING_NAMES[name:lower()] then
                        local entry=owned[item.id] or {id=item.id,name=name,sources={}}
                        entry.sources[#entry.sources+1]={bag=bag,slot=slot,status=item.status}
                        owned[item.id]=entry
                    end
                end
            end
        end
    end
    local ranked={}
    for _,entry in pairs(owned) do
        entry.score=score_name(query,entry.name)
        ranked[#ranked+1]=entry
    end
    table.sort(ranked,function(a,b)
        if a.score~=b.score then return a.score>b.score end
        return a.name<b.name
    end)
    return ranked
end

local function choose_ring(query, quiet)
    local ranked=ring_matches(query)
    if #ranked==0 then
        if not quiet then say('No Echad Ring or Warp Ring found in accessible bags.') end
        return nil
    end
    local best=ranked[1]
    if best.score<.67 then
        if not quiet then say('No confident item match for "'..query..'". Use //cu find <name>.') end
        return nil
    end
    if ranked[2] and best.score-ranked[2].score<.10 then
        if not quiet then say('Ambiguous item name: '..best.name..' / '..ranked[2].name..'. Please be more specific.') end
        return nil
    end
    return best
end

local function equip_snapshot(slotname)
    local all=windower.ffxi.get_items() or {}
    local eq=all.equipment or {}
    return {slot=tonumber(eq[slotname]) or 0,bag=tonumber(eq[slotname..'_bag']) or 0}
end
local function slot_contains(slotname,id)
    local old=equip_snapshot(slotname)
    if old.slot<=0 then return false end
    local item=windower.ffxi.get_items(old.bag,old.slot)
    return type(item)=='table' and item.id==id
end
local function ring_in_equippable(id)
    for _,bag in ipairs({0,8,10,11,12}) do
        local info=windower.ffxi.get_bag_info(bag)
        if info and info.enabled then
            for slot,item in pairs(read_bag(bag)) do
                if type(slot)=='number' and item and item.id==id and
                   (item.status==0 or item.status==5) then
                    return bag,slot,item
                end
            end
        end
    end
end
local function ring_in_storage(id)
    for _,bag in ipairs({5,6,7}) do
        local info=windower.ffxi.get_bag_info(bag)
        if info and info.enabled then
            for slot,item in pairs(read_bag(bag)) do
                if type(slot)=='number' and item and item.id==id and item.status==0 then
                    return bag,slot,item
                end
            end
        end
    end
end
local function clear_recovery()
    settings.ring_recovery=nil
    settings:save('all')
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
-- A strictly serialized ring cycle. Inventory operations stay suspended while
-- the ring is being prepared/used/restored. No GearSwap integration is assumed.
-- A recovery snapshot is saved before equipment mutation for zone/reload recovery.
local function begin_ring(query)
    if ring_job then say('A ring operation is already in progress.') return end
    if not safe() or pending then say('Finish the current transfer and leave menus/combat before using a ring.') return end
    local chosen=choose_ring(query)
    if not chosen then return end
    local id=chosen.id
    local equipping,slot,item=ring_in_equippable(id)
    local source=equipping
    if not source then
        source=ring_in_storage(id)
        if not source then say('Ring not accessible: '..chosen.name) return end
        if not bag_ready('inventory') then say('Inventory full; cannot retrieve '..chosen.name) return end
    end
    local previous=temporary[tostring(id)]
    temporary[tostring(id)]=math.max(tonumber(previous) or 0,1)
    manual=nil -- a ring workflow owns the transfer pipeline until complete
    local already=slot_contains('left_ring',id) and 'left_ring'
               or slot_contains('right_ring',id) and 'right_ring'
    ring_job={id=id, name=chosen.name, origin=source, stage=already and 'ready' or (equipping and 'equip' or 'retrieve'),
              slotname=already, original=nil, previous=previous,
              started=os.time(), stage_at=os.time(), equipping_bag=equipping,
              use_sent_at=nil, before_charges=nil}
    say(('Matched \"%s\" -> %s (%.0f%%). Preparing.'):format(query,chosen.name,chosen.score*100))
end

local function finish_ring(message)
    if not ring_job then return end
    local job=ring_job
    temporary[tostring(job.id)]=job.previous
    if job.previous==nil then temporary[tostring(job.id)]=nil end
    ring_job=nil
    clear_recovery()
    say(message)
end

local function run_ring(now)
    local job=ring_job
    if not job then return end
    if job.stage=='retrieve' then
        if ring_in_equippable(job.id) then
            job.stage='equip'; job.stage_at=now; return
        end
        if now-job.stage_at>25 then finish_ring('Could not retrieve '..job.name..' (timeout).') return end
        local bag,slot,item=ring_in_storage(job.id)
        if not bag then finish_ring('Ring source is no longer available.') return end
        if now-last_attempt<2 then return end
        issue({itemid=job.id,source=bag,dest=0,slot=slot,count=1,reason='ring use'},now)
        return
    elseif job.stage=='equip' then
        local bag,slot,item=ring_in_equippable(job.id)
        if not bag then finish_ring('Ring not available for equip.') return end
        if slot_contains('left_ring',job.id) then job.slotname='left_ring';job.stage='ready';job.stage_at=now;return end
        if slot_contains('right_ring',job.id) then job.slotname='right_ring';job.stage='ready';job.stage_at=now;return end
        -- Choose an empty ring slot if possible; otherwise temporarily replace left.
        local l=equip_snapshot('left_ring')
        local r=equip_snapshot('right_ring')
        job.slotname=l.slot==0 and 'left_ring' or (r.slot==0 and 'right_ring' or 'left_ring')
        job.original=equip_snapshot(job.slotname)
        job.stage='wait_equip';job.stage_at=now
        settings.ring_recovery={itemid=job.id,slotname=job.slotname,
            oldslot=job.original.slot,oldbag=job.original.bag,origin=job.origin}
        store()
        local slot_id=job.slotname=='left_ring' and 13 or 14
        local ok,err=pcall(windower.ffxi.set_equip,slot,slot_id,bag)
        if not ok then finish_ring('Equip failed: '..tostring(err)) return end
        say('Equipping '..job.name..' in '..job.slotname..'.')
        return
    elseif job.stage=='wait_equip' then
        if slot_contains(job.slotname,job.id) then
            job.stage='ready';job.stage_at=now;return
        end
        if now-job.stage_at>12 then job.stage='restore';say('Equip not confirmed; restoring prior ring.') end
        return
    elseif job.stage=='ready' then
        if not job.slotname or not slot_contains(job.slotname,job.id) then
            job.stage='restore';say('Ring changed before activation; restoring previous equipment.') return
        end
        local bag,slot,item=ring_in_equippable(job.id)
        if not bag or not item then job.stage='restore';return end
        local ok,ext=pcall(extdata.decode,item)
        if not ok or type(ext)~='table' or ext.type~='Enchanted Equipment' then
            job.stage='restore';say('Cannot verify enchantment readiness for '..job.name..'.') return
        end
        if ext.charges_remaining and ext.charges_remaining<=0 then
            job.stage='restore';say('No enchantment charges left on '..job.name..'.') return
        end
        if ext.usable then
            job.before_charges=ext.charges_remaining
            job.before_next_use=ext.next_use_time
            job.stage='using';job.stage_at=now;job.use_sent_at=now
            windower.send_command('input /item "'..job.name..'" <me>')
            say('Using '..job.name..'. Waiting for activation before restoring gear.')
            return
        end
        if now-job.stage_at>35 then
            job.stage='restore';say('Enchantment not ready after 35s; use cancelled.') return
        end
        return
    elseif job.stage=='using' then
        local bag,slot,item=ring_in_equippable(job.id)
        if bag and item then
            local ok,ext=pcall(extdata.decode,item)
            if ok and type(ext)=='table' and
               ((job.before_charges and ext.charges_remaining and ext.charges_remaining<job.before_charges)
                or (job.before_next_use and ext.next_use_time and ext.next_use_time~=job.before_next_use)) then
                job.stage='after_use';job.stage_at=now
                say('Ring activation observed; allowing use animation to finish before restoring.')
                return
            end
        end
        if now-job.use_sent_at>30 then
            job.stage='restore'; job.stage_at=now
            say('Activation not confirmed. Restoring gear; check whether the ring activated.')
        end
        return
    elseif job.stage=='after_use' then
        if now-job.stage_at>=3 then job.stage='restore';job.stage_at=now end
        return
    elseif job.stage=='restore' then
        if job.original then
            if slot_contains(job.slotname,job.id) then
                local old=job.original
                local slot_id=job.slotname=='left_ring' and 13 or 14
                local ok,err=pcall(windower.ffxi.set_equip,old.slot,slot_id,old.bag)
                if not ok then say('Could not restore prior ring: '..tostring(err)) return end
                job.stage='wait_restore';job.stage_at=now
                return
            end
            -- Someone changed the ring slot; don't overwrite their new gear.
        end
        job.stage='stow';job.stage_at=now;return
    elseif job.stage=='wait_restore' then
        local old=job.original
        local snap=equip_snapshot(job.slotname)
        if snap.slot==old.slot and snap.bag==old.bag then
            job.stage='stow';job.stage_at=now;return
        end
        if now-job.stage_at>12 then
            say('Prior equipment restoration unconfirmed; leaving ring in place for manual recovery.')
            finish_ring('Stopped: prior equipment restoration needs checking.')
        end
        return
    elseif job.stage=='stow' then
        if not ring_sources[job.origin] or job.origin==0 then
            finish_ring(job.name..' cycle finished; original item location preserved.')
            return
        end
        if total(0,job.id)==0 then finish_ring(job.name..' returned to its source bag.') return end
        if not bag_ready(bag_display(job.origin)) then
            finish_ring('No space in original bag; '..job.name..' remains in inventory.')
            return
        end
        local ss=stacks(0,job.id)
        if #ss==0 then
            if now-job.stage_at>12 then
                finish_ring('Unable to return '..job.name..' (still equipped/locked).')
            end
            return
        end
        if now-last_attempt<2 then return end
        issue({itemid=job.id,source=0,dest=job.origin,slot=ss[1].slot,count=1,reason='ring return'},now)
        return
    end
end

local function tick()
    local now=os.time()
    if now==last_scan then return end
    last_scan=now
    if not safe() then return end
    if settle_pending(now) then return end
    if ring_job then run_ring(now); return end
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
    if ring_job then say('Ring operation: '..ring_job.name..' ['..ring_job.stage..']') end
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
local function set_cleanup_mode(value)
    settings.cleanupmode=value
    store()
    manual=nil
    if not value and not ring_job then pending=nil end -- an active ring transaction retains its own transfer confirmation
    say('Automatic cleanup '..(value and 'ON (unassigned items go to '..settings.dumpbag..')'
        or 'OFF (new automatic moves stopped)'))
end
local function handle(command,...)
    local args={...}
    command=command and command:lower() or ''
    if command=='' or command==nil then
        set_cleanup_mode(not settings.cleanupmode)
    elseif command=='help' then
        show_help()
    elseif command=='status' then show_status()
    elseif command=='list' then list_rules()
    elseif command=='preview' then report_plan()
    elseif command=='dump' then
        local name=bag_name(table.concat(args,' '))
        if name=='inventory' or not bags[name] then say('Use //cu dump satchel|sack|case') return end
        settings.dumpbag=name;store();blocked={}
        say('Default dump bag: '..name)
    elseif command=='cleanupmode' or command=='cleanup' then
        local value=table.concat(args,' '):lower()
        if value=='' and command=='cleanup' then
            set_cleanup_mode(not settings.cleanupmode)
        elseif value=='on' or value=='off' then
            set_cleanup_mode(value=='on')
        else
            say('Usage: //cu cleanup [on|off]  (or //cu cleanupmode on|off)')
        end
    elseif command=='tidy' or command=='apply' then
        if ring_job then say('Ring operation active; retry tidy when it finishes.') return end
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
        set_cleanup_mode(false)
    elseif command=='recover' then
        local r=settings.ring_recovery
        if not r then say('No interrupted ring recovery saved.') return end
        if ring_job then say('Finish the active ring operation first.') return end
        if not safe() then say('Try recovery when idle and out of menus.') return end
        local name=r.slotname
        if name~='left_ring' and name~='right_ring' then say('Invalid saved ring slot; no changes made.') return end
        if not slot_contains(name,r.itemid) then
            say('Ring slot changed since interruption; not overwriting it.')
            clear_recovery();return
        end
        local slot_id=name=='left_ring' and 13 or 14
        local ok,err=pcall(windower.ffxi.set_equip,r.oldslot,slot_id,r.oldbag)
        if ok then
            ring_job={id=r.itemid,name=label(r.itemid),origin=r.origin,stage='wait_restore',
                stage_at=os.time(),slotname=name,original={slot=r.oldslot,bag=r.oldbag}}
            say('Restoring the saved ring slot, then attempting to return the item to its source bag.')
        else say('Recovery failed: '..tostring(err)) end
    elseif command=='find' then
        local query=clean_name(table.concat(args,' '))
        if query=='' then say('Usage: //cu find <item name>') return end
        local ranked=ring_matches(query)
        if #ranked==0 then say('No supported rings in accessible bags.') return end
        help_divider(); help_heading('Owned enchantment ring matches')
        for i=1,math.min(5,#ranked) do
            local entry=ranked[i]
            emit('  '..color(entry.name,207)..' '..color('->',200)..' '..
                color(('%d%% match'):format(math.floor(entry.score*100)),0))
        end
        help_divider()
    elseif command=='use' then
        local query=clean_name(table.concat(args,' '))
        if query=='' then say('Usage: //cu use <item>') return end
        begin_ring(query)
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
        elseif #args>=1 then
            begin_ring(table.concat({command, unpack(args)},' '))
        else
            begin_ring(command)
        end
    end
end

windower.register_event('addon command',handle)
windower.register_event('prerender',tick)
windower.register_event('zone change',function()
    reset_run()
    if ring_job and (ring_job.stage=='using' or ring_job.stage=='ready' or ring_job.stage=='after_use') then
        ring_job.stage='restore'
        ring_job.stage_at=os.time()
        say('Zone change: will restore ring equipment after zoning.')
    elseif ring_job then
        -- Keep the recovery snapshot, but stop issuing ring requests during zoning.
        ring_job.stage='restore'
        ring_job.stage_at=os.time()
    end
end)
windower.register_event('logout',function() reset_run() end)
windower.register_event('unload',function() reset_run() end)
windower.register_event('login',function()
    reset_run()
    say('Loaded. Cleanup '..(settings.cleanupmode and 'ON' or 'OFF')..'. Use //cu preview before enabling.')
    if settings.ring_recovery then
        say('Previous ring operation interrupted. Saved ring slot recovery: '..
            tostring(settings.ring_recovery.slotname)..'. Use //cu recover to retry.')
    end
end)
