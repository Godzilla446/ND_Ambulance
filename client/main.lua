local data_animations = require("data.animations")
local data_weapons = require("data.weapons")
local data_bone_settings = require("data.bone_settings")
local data_bones = require("data.bones")
local data_knockout = require("data.knockout")
local data_death = require("data.death")

local respawnKeybindLetter = ""
local randomDeathAnim = nil
local downAnim = nil
local deathState = nil
local lastSync = nil
local bleedOutTimer = nil
local knockedOut = false
local bleeding = 0
local bodyBonesDamage = lib.table.deepclone(data_bone_settings)

local function revivePlayer()
    local oldPed = cache.ped
    local seat = cache.seat
    local veh = cache.vehicle
    local coords = GetEntityCoords(oldPed)
    NetworkResurrectLocalPlayer(coords.x, coords.y, coords.z, GetEntityHeading(oldPed), true, true, false)

    local ped = PlayerPedId()
    if oldPed ~= ped then
        SetEntityLocallyInvisible(oldPed)
        DeleteEntity(oldPed)
        ClearAreaOfPeds(coords.x, coords.y, coords.z, 0.2, false)
    end

    if veh and veh ~= 0 then
        SetPedIntoVehicle(ped, veh, seat)
    end
end

local function teleport(ped, coords, withVehicle)
    FreezeEntityPosition(ped, true)
    StartPlayerTeleport(cache.playerId, coords.x, coords.y, coords.z, coords.w, withVehicle, true, true)
    while IsPlayerTeleportActive() or not HasCollisionLoadedAroundEntity(ped) do Wait(10) end
end

local function getNearestRespawnPoint()
    local locations = data_death.locations
    local nearestDist = nil
    local nearestCoords = nil
    local pedCoords = GetEntityCoords(cache.ped)

    for i=1, #locations do
        local loc = locations[i]
        local dist = #(loc.xyz-pedCoords)
        if not nearestCoords or not nearestDist or dist < nearestDist then
            nearestCoords = loc
            nearestDist = dist
        end
    end

    return nearestCoords
end

-- injured walking style set depending on body part injury.
local function hurtWalk()
    for _, info in pairs(bodyBonesDamage) do        
        if info.causeLimp and info.severity > 1.0 then
            lib.requestAnimSet("move_m@injured")
            SetPedMovementClipset(cache.ped, "move_m@injured", 1)
            SetPlayerSprint(cache.playerId, false)
            SetPedMoveRateOverride(cache.ped, 0.95)
            return true
        end
    end
    if GetPedMovementClipset(cache.ped) == `move_m@injured` then
        SetPedMoveRateOverride(cache.ped, 1.0)
        ResetPedMovementClipset(cache.ped, 0)
    end
end

-- get body damage based on body parts.
local function getInjuredBoneData(bones)
    local data = {}
    for bone, info in pairs(bones) do
        if info.severity > 0 then
            if not data[bone] then
                data[bone] = info
            else
                local limb = data[bone]
                limb.suffocating = info.suffocating
                limb.fracture = info.fracture
                limb.burn = info.burn
                limb.bleeding = info.bleeding
                limb.severity = info.severity
            end
        end
    end
    return data
end

-- update the statebag for the body damage.
local function updateBodyDamage()
    if not lastSync or (GetGameTimer()-lastSync) < 5000 then return end
    lastSync = GetGameTimer()
    local state = Player(cache.serverId).state
    state:set("injuries", getInjuredBoneData(bodyBonesDamage), true)
end

local function getTotalDamageType(body, damageType)
    if not body then return 0 end

    local value = 0
    for _, info in pairs(body) do
        if info[damageType] then
            value += info[damageType]
        end
    end
    return value
end

local function getRandomDeathAnim()
    return data_animations[math.random(1, #data_animations)]
end

-- handle player death based on death state.
local function setDead(ped, dict, clip, newDeathState)
    if deathState == newDeathState then return end

    local respawnTimer = nil
    local deadTime = data_death.timer
    local lastCheckTime = GetCloudTimeAsInt()
    deathState = newDeathState
    FreezeEntityPosition(ped, true)

    if newDeathState == "eliminated" then
        SetEntityHealth(ped, 100)
        SendNUIMessage({ type = "eliminated" })
        respawnTimer = data_death.timer

        local state = Player(cache.serverId).state
        state:set("timeSinceDeath", lastCheckTime, true)
    else
        SendNUIMessage({ type = "knocked_down" })
        SetEntityHealth(ped, GetEntityMaxHealth(ped))
    end

    CreateThread(function()
        while LocalPlayer.state.dead and deathState == newDeathState do
            local ped = cache.ped

            if not IsEntityPlayingAnim(ped, dict, clip, 3) then
                TaskPlayAnim(ped, dict, clip, 47.0, 47.0, -1, 1, 0, false, false, false)
            end

            if newDeathState == "eliminated" then
                SetPedDiesWhenInjured(ped, false)
                SetEntityCanBeDamaged(ped, false)
                SetEntityInvincible(ped, true)
                SetPlayerInvincible(cache.playerId, true)

                local time = GetCloudTimeAsInt()
                if deadTime > 0 and time-lastCheckTime > 0 then
                    lastCheckTime = time
                    deadTime -= 1
                    SendNUIMessage({
                        type = "update_respawn_timer",
                        time = deadTime
                    })
                elseif deadTime == 0 then
                    SendNUIMessage({
                        type = "update_respawn_available",
                        keybind = respawnKeybindLetter
                    })
                end
            else
                local time = GetCloudTimeAsInt()
                if time-lastCheckTime > data_death.damageInterval then
                    lastCheckTime = time
                    ApplyDamageToPed(ped, data_death.damage)
                    DoScreenFadeOut(500)
                    SetTimeout(200, function()
                        DoScreenFadeIn(500)
                    end)
                end
            end

            SetEveryoneIgnorePlayer(ped, true)
            SetPedCanBeTargetted(ped, false)
            SetBlockingOfNonTemporaryEvents(ped, true)
            SetPedCanRagdollFromPlayerImpact(ped, false)

            Wait(0)
        end
    end)
end

-- set stateags and determine animation that should be playing.
local function setDeathState(newState)
    if knockedOut or deathState == "eliminated" then return end

    knockedOut = false
    local ped = PlayerPedId()

    if LocalPlayer.state.dead and deathState == "knocked" then
        newState = "eliminated"
    end

    local state = Player(cache.serverId).state
    state:set("isDead", newState, true)
    state:set("injuries", getInjuredBoneData(bodyBonesDamage), true)
    LocalPlayer.state.dead = true

    downAnim = downAnim or getRandomDeathAnim()
    local anim = downAnim[cache.vehicle and "vehicle" or newState]
    local dict, clip = anim[1], anim[2]
    lib.requestAnimDict(dict)
    setDead(ped, dict, clip, newState)
end

local function updatePreviousPlayerDeath(player)
    SetPlayerHealthRechargeMultiplier(cache.playerId, 0.0)

    if not player or not player.metadata.dead then return end
    revivePlayer()
    setDeathState("knocked")
end

local function setPlayerKnockedOut()
    local state = Player(cache.serverId).state
    state:set("knockedout", true, true)
    SendNUIMessage({ type = "knocked_out" })
    knockedOut = true
    local timeKnocked = GetCloudTimeAsInt()

    CreateThread(function()
        while knockedOut and GetCloudTimeAsInt()-timeKnocked < 30 do
            SetPedToRagdoll(cache.ped, 5000, 5000, 0, true, true, false)
            Wait(500)
        end

        state:set("knockedout", false, true)
        if not knockedOut then return end
        SendNUIMessage({ type = "ambulance_reset" })
        knockedOut = false
    end)
end

-- ND Core death system event.
AddEventHandler("ND:playerEliminated", function(info)
    Wait(2000)
    revivePlayer()

    -- set player as knocked out if injured with a non lethal weapon.
    if not knockedOut and not deathState and lib.table.contains(data_knockout, info.deathCause) then
        return setPlayerKnockedOut()
    end
    
    -- set player as knocked down dead if injured any other way.
    setDeathState("knocked")
end)

AddEventHandler("onResourceStart", function(resourceName)
    if cache.resource ~= resourceName then return end
    Wait(1000)
    local player = NDCore.getPlayer()
    updatePreviousPlayerDeath(player)
end)

RegisterNetEvent("ND:revivePlayer", function()
    if source == "" then return end
    deathState = nil
    bleeding = 0
    bodyBonesDamage = lib.table.deepclone(data_bone_settings)
    SendNUIMessage({ type = "ambulance_reset" })
    local state = Player(cache.serverId).state
    state:set("isDead", false, true)
    state:set("injuries", false, true)
    LocalPlayer.state.dead = false
end)

RegisterNetEvent("ND:characterLoaded", function(player)
    Wait(4000)
    updatePreviousPlayerDeath(player)
end)

lib.onCache("ped", function()
    SetPlayerHealthRechargeMultiplier(cache.playerId, 0.0)
end)

AddStateBagChangeHandler("injuries", nil, function(bagName, key, value, reserved, replicated)
    local ply = GetPlayerFromStateBagName(bagName)
    if ply == 0 or replicated then return end

    local src = GetPlayerServerId(ply)
    if src ~= cache.serverId or not value then return end

    for bone, limb in pairs(bodyBonesDamage) do
        local updatedLimb = value[bone]
        if updatedLimb then
            limb.suffocating = updatedLimb.suffocating
            limb.fracture = updatedLimb.fracture
            limb.burn = updatedLimb.burn
            limb.bleeding = updatedLimb.bleeding
            limb.severity = updatedLimb.severity
        end
    end
    bleeding = getTotalDamageType(bodyBonesDamage, "bleeding")
    hurtWalk()
end)

CreateThread(function()
    local notifyInfo = {
        id = "playerBleeding",
        icon = "droplet",
        iconColor = "#eb4034",
        duration = 4000,
        position = "top-center"
    }

    while true do
        Wait(3000)
        if bleeding <= 0 then goto skip end

        local bleed = math.floor(bleeding/2)

        if bleed > 0 and (GetEntityHealth(cache.ped)-100) > bleed and not deathState then
            ApplyDamageToPed(cache.ped, bleed)
            notifyInfo.title = "You're bleeding!"
            NDCore.notify(notifyInfo)
        elseif bleed > 0 and not deathState then
            bleedOutTimer = GetCloudTimeAsInt()
            setDeathState("knocked")
            notifyInfo.title = "You need help!"
            NDCore.notify(notifyInfo)
        elseif bleed > 0 and deathState == "down" and bleedOutTimer and bleedOutTimer-GetCloudTimeAsInt() > 120 then
            setDeathState("eliminated")
            notifyInfo.title = "You bled out!"
            NDCore.notify(notifyInfo)
        end

        ::skip::
    end
end)

exports("getLastDamagingWeapon", function(ped)
    for weapon, info in pairs(data_weapons) do
        if HasPedBeenDamagedByWeapon(ped, weapon, 0) then
            ClearEntityLastDamageEntity(ped)
            return info
        end
    end
end)

exports("getBodyDamage", function()
    return bodyBonesDamage
end)

exports("updateBodyDamage", function(bone, damageWeapon)
    local boneName = data_bones[bone]
    if not boneName then return end

    local boneInfo = bodyBonesDamage[boneName]
    local updateDamageOn = {"fracture", "burn", "bleeding", "suffocating"}

    for i=1, #updateDamageOn do
        local item = updateDamageOn[i]
        if damageWeapon[item] then
            if not boneInfo[item] then
                boneInfo[item] = 0
            end
            boneInfo[item] += damageWeapon.severity
            boneInfo.severity += damageWeapon.severity
        end
    end
    
    if not boneInfo.injury then
        boneInfo.injury = {}
    end

    if not lib.table.contains(boneInfo.injury, damageWeapon.injury) then
        boneInfo.injury[#boneInfo.injury+1] = damageWeapon.injury
    end

    bleeding = getTotalDamageType(bodyBonesDamage, "bleeding")
    hurtWalk()
    updateBodyDamage()
end)

local respawnKeybind = lib.addKeybind({
    name = "respawn",
    description = "Respawn when dead",
    defaultKey = data_death.keybind,
    onPressed = function(self)
        if not LocalPlayer.state.dead then return end

        local state = Player(cache.serverId).state
        if not state or GetCloudTimeAsInt()-state.timeSinceDeath < data_death.timer then return end

        deathState = nil
        DoScreenFadeOut(500)
        Wait(500)

        TriggerServerEvent("ND_Ambulance:respawnPlayer")
        Wait(200)
        
        local coords = getNearestRespawnPoint()
        teleport(cache.ped, coords, false)

        DoScreenFadeIn(500)
    end
})

respawnKeybindLetter = GetControlInstructionalButton(0, respawnKeybind.hash, 1):sub(3)
