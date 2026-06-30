-- ============================================================
--  NETHER DEBRIS MINER v7.0
--  Self-sustaining ancient debris hunter — CC:Tweaked
--
--  LEFT slot (permanent) : Chunk Controller
--  RIGHT slot (swapped)  : Geo Scanner / Ender Modem / Pickaxe
--
--  GPS positioning with dead reckoning between strip syncs.
--  Items identified by name, never by slot number.
--  3x3x3 debris sweep. Lava refuel stays near lake until full.
--  Facing + strip progress saved across server restarts.
-- ============================================================

-- ============================================================
--  CONFIG  (edit before deploying each turtle)
-- ============================================================
local CFG = {
    -- Fuel
    fuelLow      = 500,
    fuelCritical = 100,

    -- Comms
    channel         = 1337,
    modemCheckEvery = 5,

    -- GPS
    gpsTimeout = 5,

    -- Home position — set to where the turtle starts
    -- Find coords: equip modem, run: local x,y,z=gps.locate(5) print(x,y,z)
    homeX = -577,
    homeY = 15,
    homeZ = -467,

    -- Geo scanner
    scanRadius       = 8,
    geoScanEvery     = 20,
    moveBeforeRescan = 18,

    -- Strip mining
    stripLength  = 30,
    stripSpacing = 3,

    -- Auto-recall when inventory debris count reaches this. 0 = disabled.
    debrisThreshold = 0,

    debug = true,
}

-- ============================================================
--  STATE
-- ============================================================
local State = {
    x=0, y=0, z=0,   -- current GPS position
    facing=0,         -- 0=N 1=E 2=S 3=W

    cycle=0, lastModemCheck=0,
    lastGeoScan=-999,
    blocksSinceRescan=0,
    stripCount=0, stripDir=1,

    rightSlot="none",
    recallRequested=false,
    recalled=false,   -- true once home and softlocked, only manual file deletion clears this
    messages={},
}

-- ============================================================
--  LOGGING
-- ============================================================
local function log(m)  if CFG.debug then print("[M] "..tostring(m)) end end
local function warn(m) print("[W] "..tostring(m)) end
local function err(m)  print("[E] "..tostring(m)) end

-- ============================================================
--  FORWARD DECLARATIONS
--  (functions that are called before they are defined)
-- ============================================================
local equipPickaxe
local equipGeoScanner
local equipModem
local saveState

-- ============================================================
--  DIRECTION
-- ============================================================
local DIR    = {[0]={x=0,z=-1},[1]={x=1,z=0},[2]={x=0,z=1},[3]={x=-1,z=0}}
local DNAME  = {[0]="N",[1]="E",[2]="S",[3]="W"}

local function turnRight() turtle.turnRight(); State.facing=(State.facing+1)%4 end
local function turnLeft()  turtle.turnLeft();  State.facing=(State.facing-1)%4 end

local function faceDir(t)
    local d=(t-State.facing)%4
    if     d==1 then turnRight()
    elseif d==2 then turnRight(); turnRight()
    elseif d==3 then turnLeft() end
end

-- Spin until definitely facing target
local function faceHard(t)
    for _=1,4 do
        if State.facing==t then return end
        turnRight()
    end
    err("faceHard: stuck facing "..DNAME[State.facing].." want "..DNAME[t])
end

-- ============================================================
--  GPS
-- ============================================================
local function gpsLocate()
    local x,y,z = gps.locate(CFG.gpsTimeout)
    if not x then return nil end
    return math.floor(x+0.5), math.floor(y+0.5), math.floor(z+0.5)
end

-- Equip modem, get a fix, update State, re-equip pickaxe.
-- This is now the ONLY source of truth for position — no dead reckoning.
local function gpsSync()
    equipModem()
    local x,y,z = gpsLocate()
    equipPickaxe()
    if not x then
        err("GPS sync failed — position may be stale!")
        return false
    end
    State.x, State.y, State.z = x, y, z
    return true
end

-- ============================================================
--  SAFE MOVEMENT  (every move is GPS-verified, no dead reckoning)
-- ============================================================
local function digAndMove(moveFn, digFn)
    local tries=0
    while not moveFn() do
        tries=tries+1
        if tries>10 then
            err("Stuck x10 — forcing pickaxe re-equip")
            equipPickaxe(); sleep(0.5)
            if moveFn() then
                gpsSync()
                State.blocksSinceRescan=State.blocksSinceRescan+1
                return true
            end
            return false
        end
        digFn(); sleep(0.3)
    end
    gpsSync()  -- always confirm real position after a successful move
    State.blocksSinceRescan=State.blocksSinceRescan+1
    return true
end

local function moveForward() return digAndMove(turtle.forward, turtle.dig)    end
local function moveUp()      return digAndMove(turtle.up,      turtle.digUp)   end
local function moveDown()    return digAndMove(turtle.down,    turtle.digDown) end

-- Navigate to an absolute world position. Re-derives the remaining delta
-- from a fresh GPS reading before every leg, so any drift self-corrects
-- instead of compounding.
local function navTo(tx, ty, tz)
    gpsSync()
    local dy=ty-State.y
    if dy>0 then for _=1,dy  do moveUp()   end
    elseif dy<0 then for _=1,-dy do moveDown() end end

    gpsSync()
    local dx=tx-State.x
    if dx>0 then faceDir(1); for _=1,dx  do moveForward() end
    elseif dx<0 then faceDir(3); for _=1,-dx do moveForward() end end

    gpsSync()
    local dz=tz-State.z
    if dz>0 then faceDir(2); for _=1,dz  do moveForward() end
    elseif dz<0 then faceDir(0); for _=1,-dz do moveForward() end end
end

-- ============================================================
--  INVENTORY HELPERS
-- ============================================================
local function findSlot(pattern)
    for s=1,16 do
        local d=turtle.getItemDetail(s)
        if d and d.name:lower():find(pattern,1,true) then return s end
    end
    return nil
end

local function findFreeSlot()
    for s=1,16 do if turtle.getItemCount(s)==0 then return s end end
    return nil
end

local KEEP_EXACT = {
    ["minecraft:ancient_debris"]              = true,
    ["minecraft:bucket"]                      = true,
    ["minecraft:lava_bucket"]                 = true,
    ["computercraft:wireless_modem_advanced"] = true,
}
local KEEP_SUB = {"pickaxe","geo_scanner","chunk"}

local function shouldKeep(d)
    if not d then return false end
    if KEEP_EXACT[d.name] then return true end
    local n=d.name:lower()
    for _,p in ipairs(KEEP_SUB) do if n:find(p,1,true) then return true end end
    return false
end

local function dropJunk()
    for s=1,16 do
        local d=turtle.getItemDetail(s)
        if d and not shouldKeep(d) then turtle.select(s); turtle.drop() end
    end
    turtle.select(1)
end

local function countDebris()
    local n=0
    for s=1,16 do
        local d=turtle.getItemDetail(s)
        if d and d.name=="minecraft:ancient_debris" then n=n+d.count end
    end
    return n
end

-- ============================================================
--  UPGRADE SWAPPING  (two-swap pattern — verified correct)
-- ============================================================
local function equipRight(pattern, label)
    if State.rightSlot==label then return true end

    -- Step 1: unload current upgrade into a free slot
    if State.rightSlot~="none" then
        local free=findFreeSlot()
        if not free then err("No free slot to unequip "..State.rightSlot); return false end
        turtle.select(free)
        turtle.equipRight()  -- old upgrade → free slot, right → empty
    end

    -- Step 2: find new item in inventory and equip it
    local slot=findSlot(pattern)
    if not slot then
        err("Item not found: "..label.." (pattern='"..pattern.."')")
        State.rightSlot="none"
        return false
    end
    turtle.select(slot)
    if not turtle.equipRight() then
        err("equipRight() failed for "..label)
        State.rightSlot="none"; turtle.select(1); return false
    end

    sleep(0.3)  -- give peripheral time to register

    -- Verify peripheral registered (skip for pickaxe — it's a tool not a peripheral)
    if label~="pickaxe" then
        local pt=peripheral.getType("right")
        if not pt then
            err("No peripheral registered after equipping "..label)
            State.rightSlot="none"; turtle.select(1); return false
        end
        log("Equipped: "..label.." ["..pt.."]")
    else
        log("Equipped: pickaxe")
    end

    State.rightSlot=label
    turtle.select(1)
    return true
end

-- Assign forward-declared variables
equipPickaxe    = function() return equipRight("pickaxe",      "pickaxe")    end
equipGeoScanner = function() return equipRight("geo_scanner",  "geoscanner") end
equipModem      = function() return equipRight("wireless_modem","modem")     end

-- ============================================================
--  GEO SCANNER
-- ============================================================
local function getScanner()
    local s=peripheral.find("advancedPeripherals:geo_scanner")
    if s then return s end
    local pt=peripheral.getType("right")
    if pt and pt:lower():find("geo",1,true) then return peripheral.wrap("right") end
    return nil
end

local function geoScan()
    if not equipGeoScanner() then return nil end
    sleep(0.2)
    local sc=getScanner()
    if not sc then
        err("Geo scanner missing after equip (right="..tostring(peripheral.getType("right"))..")")
        return nil
    end
    local res,e=sc.scan(CFG.scanRadius)
    if not res then err("Scan failed: "..tostring(e)); return nil end
    log("Scan: "..#res.." blocks")
    return res
end

-- Filter scan results by name, convert to absolute world coords, sort by distance
local function filterScan(results, name)
    local out={}
    for _,b in ipairs(results) do
        if b.name==name then
            out[#out+1]={
                wx=State.x+b.x, wy=State.y+b.y, wz=State.z+b.z,
                dist=math.abs(b.x)+math.abs(b.y)+math.abs(b.z),
            }
        end
    end
    table.sort(out, function(a,b) return a.dist<b.dist end)
    return out
end

-- ============================================================
--  MODEM / COMMS
-- ============================================================
local TURTLE_ID = os.getComputerID()

local function getFuelMax()
    local lim=turtle.getFuelLimit()
    if lim=="unlimited" then return nil end
    return tonumber(lim) or 20000
end

local function openModem()
    if not equipModem() then return nil end
    local m=peripheral.find("modem")
    if not m then err("No modem peripheral after equip"); return nil end
    m.open(CFG.channel)
    return m
end

local function statusPacket(ptype, extra)
    local p={
        type   =ptype,
        id     =TURTLE_ID,
        fuel   =turtle.getFuelLevel(),
        fuelMax=getFuelMax() or -1,
        pos    ={x=State.x, y=State.y, z=State.z},
        facing =State.facing,
        cycle  =State.cycle,
        strips =State.stripCount,
        debris =countDebris(),
        state  =State.recallRequested and "recalling" or "mining",
        debrisThreshold=CFG.debrisThreshold,
        scanRadius=CFG.scanRadius,
        stripLength=CFG.stripLength,
    }
    if extra then for k,v in pairs(extra) do p[k]=v end end
    return p
end

local function broadcastStatus()
    local m=openModem(); if not m then return end
    m.transmit(CFG.channel, CFG.channel, textutils.serialize(statusPacket("status")))
    m.close(CFG.channel)
    log("Status sent")
end

local function broadcastSOS()
    local m=openModem()
    if not m then err("SOS failed — no modem"); return end
    local pkt=statusPacket("sos",{msg="CRITICAL FUEL"})
    for _=1,3 do
        m.transmit(CFG.channel, CFG.channel, textutils.serialize(pkt))
        sleep(0.2)
    end
    m.close(CFG.channel)
    err("SOS sent (fuel="..turtle.getFuelLevel()..")")
end

local function checkMessages()
    local m=openModem(); if not m then return end
    local t=os.startTimer(1.5)  -- wider window to reduce chance of missing a command
    while true do
        local ev,_,ch,_,msg=os.pullEventRaw()
        -- modem_message: side, channel, replyChannel, message, distance
        if ev=="modem_message" and ch==CFG.channel then
            State.messages[#State.messages+1]=msg
        elseif ev=="timer" then break end
    end
    m.close(CFG.channel)
end

local function processMessages()
    for _,raw in ipairs(State.messages) do
        local ok,d=pcall(textutils.unserialize,raw)
        if ok and type(d)=="table" then
            if d.target and d.target~=TURTLE_ID then
                -- not for us, ignore
            elseif d.cmd=="recall" then
                log("RECALL received")
                State.recallRequested=true
                saveState()  -- persist immediately so a shutdown mid-journey still remembers
            elseif d.cmd=="ping" then
                log("Ping received")
            elseif d.cmd=="config" then
                if d.scanRadius      then CFG.scanRadius     =tonumber(d.scanRadius);      log("Config: scanRadius="..CFG.scanRadius) end
                if d.stripLength     then CFG.stripLength    =tonumber(d.stripLength);     log("Config: stripLength="..CFG.stripLength) end
                if d.debrisThreshold then CFG.debrisThreshold=tonumber(d.debrisThreshold); log("Config: debrisThreshold="..CFG.debrisThreshold) end
                saveState()
            end
        end
    end
    State.messages={}
end

-- ============================================================
--  PERSISTENT STATE
-- ============================================================
local SAVE_FILE="miner_state.cfg"

saveState = function()
    local f=fs.open(SAVE_FILE,"w")
    if not f then err("Cannot save state"); return end
    f.write(textutils.serialize({
        facing          = State.facing,
        stripCount      = State.stripCount,
        stripDir        = State.stripDir,
        scanRadius      = CFG.scanRadius,
        stripLength     = CFG.stripLength,
        debrisThreshold = CFG.debrisThreshold,
        recallRequested = State.recallRequested,
        recalled        = State.recalled,
    }))
    f.close()
end

local function loadState()
    if not fs.exists(SAVE_FILE) then return false end
    local f=fs.open(SAVE_FILE,"r")
    if not f then return false end
    local ok,d=pcall(textutils.unserialize, f.readAll())
    f.close()
    if not ok or type(d)~="table" then err("Corrupt save file — ignoring"); return false end
    State.facing     = d.facing     or 0
    State.stripCount = d.stripCount or 0
    State.stripDir   = d.stripDir   or 1
    -- Restore remote-configurable settings if previously changed
    if d.scanRadius      then CFG.scanRadius      = d.scanRadius end
    if d.stripLength     then CFG.stripLength     = d.stripLength end
    if d.debrisThreshold then CFG.debrisThreshold = d.debrisThreshold end
    -- Restore recall intent — survives a shutdown mid-journey home
    State.recallRequested = d.recallRequested or false
    State.recalled         = d.recalled        or false
    log("Loaded: facing="..DNAME[State.facing].." strip="..State.stripCount
        ..(State.recallRequested and " [RECALL PENDING]" or "")
        ..(State.recalled and " [SOFTLOCKED AT HOME]" or ""))
    return true
end

-- ============================================================
--  FUEL / REFUELING
-- ============================================================
local function fuelOk()
    local max=getFuelMax()
    return (not max) or turtle.getFuelLevel()>CFG.fuelLow
end

local function doRefuel()
    local max=getFuelMax()
    if not max then return true end

    log("Refueling: "..turtle.getFuelLevel().."/"..max)

    local returnX,returnY,returnZ = State.x,State.y,State.z
    local returnFacing = State.facing

    local failedSpots={}
    local failStreak=0
    local atLavaArea=false

    local function isFailedSpot(wx,wy,wz)
        for _,s in ipairs(failedSpots) do
            if s.x==wx and s.y==wy and s.z==wz then return true end
        end
        return false
    end

    while turtle.getFuelLevel()<max do
        local results=geoScan()
        if not results then
            failStreak=failStreak+1
            warn("Scan fail "..failStreak.."/5"); sleep(5)
            if failStreak>=5 then err("Too many scan failures — aborting refuel"); break end
        else
            failStreak=0
            local lavaList=filterScan(results,"minecraft:lava")

            local goodLava={}
            for _,lv in ipairs(lavaList) do
                if not isFailedSpot(lv.wx,lv.wy,lv.wz) then
                    goodLava[#goodLava+1]=lv
                end
            end

            if #goodLava==0 then
                if not atLavaArea then
                    warn("No lava in range — nudging forward...")
                    equipPickaxe()
                    for _=1,5 do moveForward() end
                else
                    warn("All nearby lava failed — waiting for reflow...")
                    failedSpots={}; sleep(3)
                end
            else
                local lv=goodLava[1]
                log("Going to lava at "..lv.wx..","..lv.wy..","..lv.wz)
                atLavaArea=true

                local bkt=findSlot("bucket")
                if not bkt then err("No bucket in inventory!"); break end

                equipPickaxe()

                local filled=false
                if lv.wy < State.y then
                    navTo(lv.wx, lv.wy+1, lv.wz)
                    turtle.select(bkt); filled=turtle.placeDown()
                elseif lv.wy > State.y then
                    navTo(lv.wx, lv.wy-1, lv.wz)
                    turtle.select(bkt); filled=turtle.placeUp()
                else
                    if math.abs(lv.wz-State.z)>=math.abs(lv.wx-State.x) then
                        if lv.wz>State.z then navTo(lv.wx,lv.wy,lv.wz-1); faceHard(2)
                        else                  navTo(lv.wx,lv.wy,lv.wz+1); faceHard(0) end
                    else
                        if lv.wx>State.x then navTo(lv.wx-1,lv.wy,lv.wz); faceHard(1)
                        else                  navTo(lv.wx+1,lv.wy,lv.wz); faceHard(3) end
                    end
                    turtle.select(bkt); filled=turtle.place()
                end

                if filled then
                    local lb=findSlot("lava_bucket") or findSlot("bucket")
                    if lb then
                        turtle.select(lb)
                        if turtle.refuel(1) then
                            log("Refueled → "..turtle.getFuelLevel().."/"..max)
                        else warn("refuel() returned false") end
                    end
                else
                    warn("Fill failed at "..lv.wx..","..lv.wy..","..lv.wz.." — marking as flowing")
                    failedSpots[#failedSpots+1]={x=lv.wx,y=lv.wy,z=lv.wz}
                end
                turtle.select(1)
            end
        end
    end

    log("Tank full ("..turtle.getFuelLevel()..") — returning to mining position")
    equipPickaxe()
    navTo(returnX, returnY, returnZ)
    faceDir(returnFacing)
    return true
end

-- ============================================================
--  DEBRIS MINING  (3x3x3 sweep)
-- ============================================================
local function scanForDebris()
    local results=geoScan()
    if not results then return nil end
    local list=filterScan(results,"minecraft:ancient_debris")
    if #list==0 then log("No debris in range"); return nil end
    log("Debris: "..#list.." blocks, nearest="..list[1].wx..","..list[1].wy..","..list[1].wz)
    return list[1]
end

-- Quick poll for incoming commands without the full broadcast overhead.
-- Used inside long-running operations (debris sweep, refuel) so recall
-- can actually be detected mid-operation, not just checked-for after.
local function quickPollRecall()
    checkMessages()
    processMessages()
    return State.recallRequested
end

local function sweep3x3x3(cx,cy,cz)
    log("3x3x3 sweep at "..cx..","..cy..","..cz)
    local mined=0
    local posCount=0
    for dx=-1,1 do for dy=-1,1 do for dz=-1,1 do
        if not(dx==0 and dy==0 and dz==0) then
            posCount = posCount + 1

            -- Actively poll for an incoming recall every few positions in
            -- the sweep — this is the only place recall can actually be
            -- detected during a sweep, since nothing else in this loop
            -- touches the modem.
            if posCount % 4 == 0 then
                if quickPollRecall() then
                    log("Recall detected mid-sweep — aborting remaining sweep")
                    equipPickaxe()
                    return
                end
                equipPickaxe()  -- quickPollRecall swaps to the modem, restore pickaxe
            end

            local tx,ty,tz = cx+dx, cy+dy, cz+dz
            local ax,ay,az = math.abs(dx),math.abs(dy),math.abs(dz)

            if ay>=ax and ay>=az then
                navTo(tx, dy>0 and ty-1 or ty+1, tz)
                local ok,data
                if dy>0 then
                    ok,data=turtle.inspectUp()
                else
                    ok,data=turtle.inspectDown()
                end
                if ok and data and data.name=="minecraft:ancient_debris" then
                    if dy>0 then turtle.digUp() else turtle.digDown() end
                    mined=mined+1
                end
            else
                local adjX,adjZ,face = tx,tz,0
                if az>=ax then
                    adjZ = dz>0 and tz-1 or tz+1
                    face = dz>0 and 2 or 0
                else
                    adjX = dx>0 and tx-1 or tx+1
                    face = dx>0 and 1 or 3
                end
                navTo(adjX, ty, adjZ)
                faceHard(face)
                local ok,data=turtle.inspect()
                if ok and data.name=="minecraft:ancient_debris" then
                    turtle.dig(); mined=mined+1
                end
            end
        end
    end end end
    log("Sweep done — mined "..mined.." debris")
end

local function mineToDebris(target)
    log("Mining debris at "..target.wx..","..target.wy..","..target.wz)
    equipPickaxe()

    local retX,retY,retZ = State.x,State.y,State.z
    local retF = State.facing

    local tx,ty,tz = target.wx,target.wy,target.wz
    local rx,ry,rz = tx-State.x, ty-State.y, tz-State.z
    local ax,ay,az = math.abs(rx),math.abs(ry),math.abs(rz)

    -- Navigate adjacent and mine the debris block
    if ay>=ax and ay>=az then
        if ry>0 then navTo(tx,ty-1,tz); turtle.digUp()
        else         navTo(tx,ty+1,tz); turtle.digDown() end
    elseif az>=ax then
        if rz>0 then navTo(tx,ty,tz-1); faceHard(2)
        else         navTo(tx,ty,tz+1); faceHard(0) end
        turtle.dig()
    else
        if rx>0 then navTo(tx-1,ty,tz); faceHard(1)
        else         navTo(tx+1,ty,tz); faceHard(3) end
        turtle.dig()
    end

    -- Full 3x3x3 sweep around the debris
    sweep3x3x3(tx, ty, tz)

    log("Done. Debris in inventory: "..countDebris())

    navTo(retX, retY, retZ)
    faceDir(retF)
    State.blocksSinceRescan=0
end

-- ============================================================
--  STRIP MINING
-- ============================================================
local function mineStrip()
    equipPickaxe()
    log("Strip "..State.stripCount)
    for i=1,CFG.stripLength do
        turtle.dig(); turtle.digUp()
        moveForward()
        dropJunk()

        if turtle.getFuelLevel()<=CFG.fuelCritical then
            err("Critical fuel mid-strip"); break
        end

        -- Check for recall every few blocks so it can break out immediately
        -- rather than waiting for the whole strip (up to 30 blocks) to finish
        if i % 3 == 0 then
            checkMessages()
            processMessages()
            broadcastStatus()           -- send a status update on this check too
            equipPickaxe()              -- CRITICAL: re-equip pickaxe after modem swap
            if State.rightSlot ~= "pickaxe" then
                err("Pickaxe re-equip failed after mid-strip modem check!")
            end
            if State.recallRequested then
                log("Recall detected mid-strip — aborting")
                break
            end
        end
    end
    State.stripCount=State.stripCount+1
end

local function moveToNextStrip()
    equipPickaxe()
    if State.stripDir==1 then turnRight() else turnLeft() end
    for _=1,CFG.stripSpacing do moveForward() end
    if State.stripDir==1 then turnLeft() else turnRight() end
    State.stripDir=-State.stripDir
end

-- ============================================================
--  RECALL
-- ============================================================
local RECALL_BROADCAST_EVERY_BLOCKS = 15  -- broadcast roughly this often during the trip home, much less frequent than normal mining

local function doRecall()
    log("=== RECALL — navigating home ===")
    equipPickaxe()
    gpsSync()  -- force a fresh fix before computing any deltas, no stale data

    -- Navigate home in chunks so we can broadcast occasionally without
    -- spamming the modem on every single block like normal mining does
    -- navTo moves in straight axis-aligned legs (Y, then X, then Z). We wrap
    -- it with periodic broadcasts by chunking the distance into smaller hops.
    local function hop(axis, dist)
        if dist == 0 then return end  -- nothing to do on this axis

        local stepSize = RECALL_BROADCAST_EVERY_BLOCKS
        local remaining = math.abs(dist)
        local positive = dist > 0

        log("hop axis="..axis.." dist="..dist.." positive="..tostring(positive))

        while remaining > 0 do
            local step = math.min(stepSize, remaining)
            if axis=="y" then
                if positive then for _=1,step do moveUp() end
                else             for _=1,step do moveDown() end end
            elseif axis=="x" then
                faceDir(positive and 1 or 3)  -- +X=East(1)  -X=West(3)
                for _=1,step do moveForward() end
            elseif axis=="z" then
                faceDir(positive and 2 or 0)  -- +Z=South(2) -Z=North(0)
                for _=1,step do moveForward() end
            end
            remaining = remaining - step
            broadcastStatus()  -- infrequent update so master sees progress without spamming
        end
    end

    local dyTotal = CFG.homeY - State.y
    local dxTotal = CFG.homeX - State.x
    local dzTotal = CFG.homeZ - State.z
    log("Recall deltas: dy="..dyTotal.." dx="..dxTotal.." dz="..dzTotal
        .." (current="..State.x..","..State.y..","..State.z
        .." home="..CFG.homeX..","..CFG.homeY..","..CFG.homeZ..")")

    hop("y", dyTotal)
    hop("x", dxTotal)
    hop("z", dzTotal)

    log("Home. Softlocked — delete '"..SAVE_FILE.."' on this turtle to resume mining.")
    State.recalled = true
    saveState()  -- persist the softlock immediately so a restart stays locked
    broadcastStatus()
end

-- ============================================================
--  JUMPSTART
-- ============================================================
local function tryJumpstart()
    log("Fuel=0 — scanning for burnable items...")
    for s=1,16 do
        turtle.select(s)
        if turtle.refuel(1) then
            log("Jumpstarted from slot "..s.." fuel="..turtle.getFuelLevel())
            turtle.select(1); return true
        end
    end
    turtle.select(1); return false
end

-- ============================================================
--  FACING CALIBRATION  (move forward, compare GPS before/after)
-- ============================================================
local function calibrateFacing()
    log("Calibrating facing via GPS...")
    equipModem()
    local x1,_,z1 = gpsLocate()
    if not x1 then
        err("GPS unavailable for calibration — defaulting to North")
        equipPickaxe()
        State.facing=0
        return false
    end

    -- Try moving forward; if blocked try each direction
    local moved=false
    for attempt=1,4 do
        if turtle.forward() then moved=true; break end
        turnRight()
    end

    if not moved then
        err("Completely blocked — cannot calibrate facing")
        equipPickaxe(); return false
    end

    local x2,_,z2 = gpsLocate()
    turtle.back()
    equipPickaxe()

    if not x2 then
        warn("GPS failed after move — defaulting facing to North")
        State.facing=0; return false
    end

    local dx,dz = x2-x1, z2-z1
    log("GPS delta: dx="..dx.." dz="..dz.." (before="..x1..","..z1.." after="..x2..","..z2..")")

    if     dx== 1 and dz== 0 then State.facing=1  -- +X = East
    elseif dx==-1 and dz== 0 then State.facing=3  -- -X = West
    elseif dx== 0 and dz== 1 then State.facing=2  -- +Z = South
    elseif dx== 0 and dz==-1 then State.facing=0  -- -Z = North
    else
        warn("Unexpected GPS delta dx="..dx.." dz="..dz.." — defaulting North")
        State.facing=0
    end

    log("Facing: "..DNAME[State.facing])
    return true
end

-- ============================================================
--  MAIN LOOP
-- ============================================================
local function mainLoop()
    log("=== NETHER DEBRIS MINER v7.0 ===")
    log("ID="..TURTLE_ID.." Home="..CFG.homeX..","..CFG.homeY..","..CFG.homeZ)

    -- Get initial GPS fix (needs modem)
    equipModem()
    log("Getting GPS fix...")
    local gx,gy,gz = gpsLocate()
    if not gx then
        err("No GPS fix on startup! Check GPS hosts.")
        return
    end
    State.x,State.y,State.z = gx,gy,gz
    log("GPS: "..State.x..","..State.y..","..State.z)
    equipPickaxe()

    -- Load saved state or calibrate fresh
    if loadState() then
        log("Resumed from save — facing="..DNAME[State.facing])
    else
        log("First run — calibrating facing...")
        calibrateFacing()
        saveState()
    end

    -- SOFTLOCK CHECK — if previously recalled and arrived home, stay locked
    -- until a player manually deletes the save file. This also catches the
    -- case where the turtle was shut down mid-journey home: recallRequested
    -- survives the restart, so it will simply resume navigating home below
    -- rather than going back to mining.
    if State.recalled then
        err("=== SOFTLOCKED ===")
        err("This turtle was recalled and is sitting at home.")
        err("Delete '"..SAVE_FILE.."' on this turtle and restart to resume mining.")
        broadcastStatus()
        while true do
            sleep(5)
            broadcastStatus()  -- keep reporting in so master doesn't mark offline
        end
        return
    end

    -- If recall was requested but the turtle never made it home (e.g. server
    -- restarted mid-journey), resume the trip home immediately rather than
    -- going back to mining.
    if State.recallRequested then
        log("Recall was pending before restart — resuming trip home")
        doRecall()
        return
    end

    while true do
        State.cycle=State.cycle+1

        -- 0. RECALL
        if State.recallRequested then doRecall(); return end

        -- 0.5 DEBRIS THRESHOLD AUTO-RECALL
        if CFG.debrisThreshold > 0 and countDebris() >= CFG.debrisThreshold then
            log("Debris threshold reached ("..countDebris().."/"..CFG.debrisThreshold..") — auto-recalling")
            State.recallRequested = true
            doRecall()
            return
        end

        -- 1. FUEL MANAGEMENT
        local fuel=turtle.getFuelLevel()
        if fuel==0 then
            if not tryJumpstart() then
                err("Stranded — waiting for fuel...")
                broadcastSOS()
                repeat sleep(2) until tryJumpstart()
            end
        elseif fuel<=CFG.fuelCritical then
            err("Critical fuel="..fuel)
            broadcastSOS(); doRefuel()
            if turtle.getFuelLevel()<=CFG.fuelCritical then
                err("Emergency refuel failed"); broadcastSOS()
            end
        elseif not fuelOk() then
            doRefuel()
        end

        -- 2. MODEM CHECK
        if (State.cycle-State.lastModemCheck)>=CFG.modemCheckEvery then
            checkMessages(); processMessages(); broadcastStatus()
            State.lastModemCheck=State.cycle
        end
        if State.recallRequested then doRecall(); return end  -- recall may have just arrived

        -- 3. PERIODIC DEBRIS SCAN
        if (State.cycle-State.lastGeoScan)>=CFG.geoScanEvery and fuelOk() then
            State.lastGeoScan=State.cycle
            local d=scanForDebris()
            if d then mineToDebris(d) end
        end
        if State.recallRequested then doRecall(); return end

        -- 4. MOVEMENT-TRIGGERED RESCAN
        if State.blocksSinceRescan>=CFG.moveBeforeRescan and fuelOk() then
            State.blocksSinceRescan=0
            State.lastGeoScan=State.cycle
            local d=scanForDebris()
            if d then mineToDebris(d) end
        end
        if State.recallRequested then doRecall(); return end

        -- 5. MINE
        mineStrip()
        if State.recallRequested then doRecall(); return end  -- mineStrip may have detected recall mid-strip
        moveToNextStrip()
        saveState()  -- persist facing + strip progress (position itself is always live via GPS)

        sleep(0.05)
    end
end

-- ============================================================
--  ENTRY
-- ============================================================
local ok,e=pcall(mainLoop)
if not ok then err("FATAL: "..tostring(e)); print("Halted.") end
