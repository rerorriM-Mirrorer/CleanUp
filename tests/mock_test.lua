-- Local Windower simulation only; not a substitute for live FFXI testing.
local events={}
local messages={}
local clock=100000
os.time=function() return clock end
local fmt_items={
 [101]={en='Echad Ring'},[102]={en='Warp Ring'},[103]={en='Sole Sushi'},[110]={en='Old Ring'},
}
local contents={}
for _,bag in ipairs({0,5,6,7,8,10,11,12}) do contents[bag]={} end
contents[5][4]={id=101,count=1,status=0,slot=4,charges_remaining=1,usable=true,next_use_time=0}
contents[7][5]={id=102,count=1,status=0,slot=5,charges_remaining=1,usable=true,next_use_time=0}
contents[0][1]={id=110,count=1,status=5,slot=1}
local equipment={left_ring=1,left_ring_bag=0,right_ring=0,right_ring_bag=0}
local mode_commands={}
_addon={}
unpack = unpack or table.unpack
windower={}
function windower.register_event(event,callback) events[event]=callback end
function windower.add_to_chat(mode,msg) assert(mode==0);messages[#messages+1]=msg end
windower.ffxi={}
function windower.ffxi.get_info() return {logged_in=true,menu_open=false} end
function windower.ffxi.get_player() return {status=0} end
function windower.ffxi.get_bag_info(bag)
 local n=0;for _ in pairs(contents[bag] or {}) do n=n+1 end
 return {max=80,count=n,enabled=true}
end
function windower.ffxi.get_items(bag,slot)
 if bag==nil then return {equipment=equipment} end
 if slot~=nil then return contents[bag][slot] end
 return contents[bag]
end
function windower.ffxi.move_item(src,dst,slot,count)
 local item=contents[src][slot]
 assert(item and item.count>=count and item.status==0, 'invalid move')
 local free=1;while contents[dst][free] do free=free+1 end
 contents[dst][free]={id=item.id,count=count,status=0,slot=free,charges_remaining=item.charges_remaining,usable=item.usable,next_use_time=item.next_use_time}
 item.count=item.count-count;if item.count==0 then contents[src][slot]=nil end
end
function windower.ffxi.set_equip(index,slot,bag)
 local name=slot==13 and 'left_ring' or 'right_ring'
 local oldslot=equipment[name];local oldbag=equipment[name..'_bag']
 if oldslot>0 and contents[oldbag][oldslot] then contents[oldbag][oldslot].status=0 end
 if index>0 then
  assert(contents[bag][index] and contents[bag][index].id~=0,'equip missing')
  contents[bag][index].status=5
 end
 equipment[name]=index;equipment[name..'_bag']=bag
end
function windower.send_command(cmd)
 mode_commands[#mode_commands+1]=cmd
 if cmd:find('input /item ',1,true) then
   local ring_name=cmd:match('"(.-)"')
   for _,bag in ipairs({0,5,6,7,8,10,11,12}) do
    for _,item in pairs(contents[bag]) do
     if fmt_items[item.id].en==ring_name then
       assert(item.status==5,'use was not equipped')
       item.charges_remaining=item.charges_remaining-1
       item.next_use_time=clock
     end
    end
   end
   if ring_name=='Warp Ring' and events['zone change'] then events['zone change']() end
 end
end
package.preload['config']=function()
 local settings={cleanupmode=false,dumpbag='case',delay=2,homes={},inventory={},debug=false}
 function settings:save(_) end
 return {load=function(_) return settings end}
end
package.preload['resources']=function() return {items=fmt_items} end
package.preload['chat']=function() string.color=function(s,n) return '<'..n..'>'..s end;return {} end
package.preload['extdata']=function() return {decode=function(item) return {type=item.charges_remaining and 'Enchanted Equipment' or 'General', usable=item.usable,charges_remaining=item.charges_remaining,next_use_time=item.next_use_time} end} end

local f=assert(loadfile('CleanUp.lua'))
f()
local function cmd(...) events['addon command'](...) end
local function tick(n)
 for i=1,n do clock=clock+1;events.prerender() end
end
cmd() -- bare toggles on
assert(#messages>0 and messages[#messages]:find('ON'))
cmd('cleanup') -- toggles off
assert(messages[#messages]:find('OFF'))
cmd('cleanup','on')
assert(messages[#messages]:find('ON'))
cmd('cleanupmode','off')
assert(messages[#messages]:find('OFF'))
cmd('find','ech','ring')
assert(messages[#messages]:find('140'))
cmd('ech','ring')
tick(45)
local function in_bag(bag,id) for _,it in pairs(contents[bag]) do if it.id==id then return true end end return false end
assert(in_bag(5,101),'Echad ring not back in satchel')
assert(equipment.left_ring==1 and equipment.left_ring_bag==0,'original left ring moved')
assert(equipment.right_ring==0,'right ring not restored empty')
local uses=0
for _,v in ipairs(mode_commands) do if v:find('input /item "Echad Ring"',1,true) then uses=uses+1 end end
assert(uses==1,'expected one Echad use, saw '..uses)
cmd('ring') -- shared suffix is deliberately ambiguous
local before=#mode_commands
assert(#mode_commands==before,'ambiguous match sent an item command')
cmd('warp','ring')
tick(45)
assert(in_bag(7,102), 'Warp Ring not back in Case')
local warpuses=0
for _,v in ipairs(mode_commands) do if v:find('input /item "Warp Ring"',1,true) then warpuses=warpuses+1 end end
assert(warpuses==1, 'warp use not found')
print('PASS: bare toggles, cleanup alias, exact commands, fuzzy ech/warp, ring equip/use/restore/source return')
print('messages:',#messages, 'commands:', #mode_commands)
