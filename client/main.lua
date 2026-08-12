local TMGCore = exports['tmg-core']:GetCoreObject()
local PlayerData = TMGCore.Functions.GetPlayerData()
local isLoggedIn = LocalPlayer.state.isLoggedIn
local playerPed = PlayerPedId()
local playerCoords = GetEntityCoords(playerPed)
local closestCityhall = nil
local closestDrivingSchool = nil
local inRangeCityhall = false
local inRangeDrivingSchool = false
local pedsSpawned = false
local blips = {}

-- Functions

-- Returns the index into Config.Cityhalls of the hall nearest the cached playerCoords.
local function getClosestHall()
    local distance = #(playerCoords - Config.Cityhalls[1].coords)
    local closest = 1
    for i = 1, #Config.Cityhalls do
        local hall = Config.Cityhalls[i]
        local dist = #(playerCoords - hall.coords)
        if dist < distance then
            distance = dist
            closest = i
        end
    end
    return closest
end

-- Returns the index into Config.DrivingSchools of the school nearest the cached playerCoords.
local function getClosestSchool()
    local distance = #(playerCoords - Config.DrivingSchools[1].coords)
    local closest = 1
    for i = 1, #Config.DrivingSchools do
        local school = Config.DrivingSchools[i]
        local dist = #(playerCoords - school.coords)
        if dist < distance then
            distance = dist
            closest = i
        end
    end
    return closest
end

-- Creates a map blip from an options table (coords, sprite, display, scale, colour, shortRange, title).
-- Raises an error if coords is missing or not a vector3/table. Returns the blip handle.
local function createBlip(options)
    if not options.coords or type(options.coords) ~= 'table' and type(options.coords) ~= 'vector3' then return error(('createBlip() expected coords in a vector3 or table but received %s'):format(options.coords)) end
    local blip = AddBlipForCoord(options.coords.x, options.coords.y, options.coords.z)
    SetBlipSprite(blip, options.sprite or 1)
    SetBlipDisplay(blip, options.display or 4)
    SetBlipScale(blip, options.scale or 1.0)
    SetBlipColour(blip, options.colour or 1)
    SetBlipAsShortRange(blip, options.shortRange or false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(options.title or 'No Title Given')
    EndTextCommandSetBlipName(blip)
    return blip
end

-- Removes every blip this resource created and empties the tracking table.
local function deleteBlips()
    if not next(blips) then return end
    for i = 1, #blips do
        local blip = blips[i]
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
    end
    blips = {}
end

-- Creates blips for every cityhall and driving school that has showBlip enabled, tracking them in `blips`.
local function initBlips()
    for i = 1, #Config.Cityhalls do
        local hall = Config.Cityhalls[i]
        if hall.showBlip then
            blips[#blips + 1] = createBlip({
                coords = hall.coords,
                sprite = hall.blipData.sprite,
                display = hall.blipData.display,
                scale = hall.blipData.scale,
                colour = hall.blipData.colour,
                shortRange = true,
                title = hall.blipData.title
            })
        end
    end
    for i = 1, #Config.DrivingSchools do
        local school = Config.DrivingSchools[i]
        if school.showBlip then
            blips[#blips + 1] = createBlip({
                coords = school.coords,
                sprite = school.blipData.sprite,
                display = school.blipData.display,
                scale = school.blipData.scale,
                colour = school.blipData.colour,
                shortRange = true,
                title = school.blipData.title
            })
        end
    end
end

-- Opens the top-level cityhall menu (ID card / job center / close) through tmg-menu.
local function openCityhallMenu()
    local mainMenu = {
        {
            header = 'City Hall',
            isMenuHeader = true
        },
        {
            header = 'ID Card',
            txt = 'Get your ID Card',
            params = {
                event = 'tmg-cityhall:client:openIdentityMenu'
            }
        },
        {
            header = 'Job Center',
            txt = 'Available Jobs',
            params = {
                event = 'tmg-cityhall:client:openJobMenu'
            }
        },
        {
            header = 'Close Menu',
            txt = '',
            params = {
                event = 'tmg-menu:client:closeMenu'
            }
        }
    }

    exports['tmg-menu']:openMenu(mainMenu)
end

-- Asks the server which licenses the player may buy at the closest cityhall, then opens a menu
-- with one purchase entry per license (each showing its cost).
local function openIdentityMenu()
    TMGCore.Functions.TriggerCallback('tmg-cityhall:server:getIdentityData', function(licenses)
        local identityMenu = {
            {
                header = 'Identity',
                isMenuHeader = true
            },
            {
                header = '← Go Back',
                params = {
                    event = 'tmg-cityhall:client:openCityhallMenu'
                }
            }
        }

        for license, data in pairs(licenses) do
            table.insert(identityMenu, {
                header = data.label,
                txt = 'Cost: $' .. data.cost,
                params = {
                    event = 'tmg-cityhall:client:requestId',
                    args = {
                        type = license,
                        cost = data.cost
                    }
                }
            })
        end

        exports['tmg-menu']:openMenu(identityMenu)
    end, closestCityhall)
end

-- Fetches the list of city-hall hireable jobs from the server and opens a menu where each entry applies for that job.
local function openJobMenu()
    TMGCore.Functions.TriggerCallback('tmg-cityhall:server:receiveJobs', function(jobs)
        local jobMenu = {
            {
                header = 'Job Center',
                isMenuHeader = true
            },
            {
                header = '← Go Back',
                params = {
                    event = 'tmg-cityhall:client:openCityhallMenu'
                }
            }
        }

        for jobName, jobData in pairs(jobs) do
            table.insert(jobMenu, {
                header = jobData.label,
                txt = 'Apply for this job',
                params = {
                    event = 'tmg-cityhall:client:applyJob',
                    args = {
                        job = jobName
                    }
                }
            })
        end

        exports['tmg-menu']:openMenu(jobMenu)
    end)
end

-- Spawns the configured cityhall/driving-school peds (frozen, invincible, running their scenario) and stores
-- each handle on Config.Peds[i].pedHandle. Depending on Config.UseTarget it either registers tmg-target
-- options on the ped or builds a BoxZone that toggles the inRange flags and draws the [E] prompt.
local function spawnPeds()
    if not Config.Peds or not next(Config.Peds) or pedsSpawned then return end
    for i = 1, #Config.Peds do
        local current = Config.Peds[i]
        current.model = type(current.model) == 'string' and joaat(current.model) or current.model
        RequestModel(current.model)
        while not HasModelLoaded(current.model) do
            Wait(0)
        end
        local ped = CreatePed(0, current.model, current.coords.x, current.coords.y, current.coords.z, current.coords.w, false, false)
        FreezeEntityPosition(ped, true)
        SetEntityInvincible(ped, true)
        SetBlockingOfNonTemporaryEvents(ped, true)
        TaskStartScenarioInPlace(ped, current.scenario, true, true)
        current.pedHandle = ped
        if Config.UseTarget then
            local opts = nil
            if current.drivingschool then
                opts = {
                    label = 'Take Driving Lessons',
                    icon = 'fa-solid fa-car-side',
                    action = function()
                        TriggerServerEvent('tmg-cityhall:server:sendDriverTest', Config.DrivingSchools[closestDrivingSchool].instructors)
                    end
                }
            elseif current.cityhall then
                opts = {
                    label = 'Open Cityhall',
                    icon = 'fa-solid fa-city',
                    action = function()
                        inRangeCityhall = true
                        openCityhallMenu()
                    end
                }
            end
            if opts then
                exports['tmg-target']:AddTargetEntity(ped, {
                    options = { opts },
                    distance = 2.0
                })
            end
        else
            local options = current.zoneOptions
            if options then
                local zone = BoxZone:Create(current.coords.xyz, options.length, options.width, {
                    name = 'zone_cityhall_' .. ped,
                    heading = current.coords.w,
                    debugPoly = false,
                    minZ = current.coords.z - 3.0,
                    maxZ = current.coords.z + 2.0
                })
                zone:onPlayerInOut(function(inside)
                    if isLoggedIn and closestCityhall and closestDrivingSchool then
                        if inside then
                            if current.drivingschool then
                                inRangeDrivingSchool = true
                                exports['tmg-core']:DrawText('[E] Take Driving Lessons')
                            elseif current.cityhall then
                                inRangeCityhall = true
                                exports['tmg-core']:DrawText('[E] Open Cityhall')
                            end
                        else
                            exports['tmg-core']:HideText()
                            if current.drivingschool then
                                inRangeDrivingSchool = false
                            elseif current.cityhall then
                                inRangeCityhall = false
                            end
                        end
                    end
                end)
            end
        end
    end
    pedsSpawned = true
end

-- Deletes every ped spawned by spawnPeds and clears the pedsSpawned flag. Does not remove target zones.
local function deletePeds()
    if not Config.Peds or not next(Config.Peds) or not pedsSpawned then return end
    for i = 1, #Config.Peds do
        local current = Config.Peds[i]
        if current.pedHandle then
            DeletePed(current.pedHandle)
        end
    end
    pedsSpawned = false
end

-- Events

-- Refreshes the cached PlayerData and spawns the cityhall peds once the character finishes loading.
RegisterNetEvent('TMGCore:Client:OnPlayerLoaded', function()
    PlayerData = TMGCore.Functions.GetPlayerData()
    isLoggedIn = true
    spawnPeds()
end)

-- Clears the cached PlayerData and removes the spawned peds when the player logs out of a character.
RegisterNetEvent('TMGCore:Client:OnPlayerUnload', function()
    PlayerData = {}
    isLoggedIn = false
    deletePeds()
end)

-- Keeps the local PlayerData cache in sync whenever the core pushes updated player state.
RegisterNetEvent('TMGCore:Player:SetPlayerData', function(val)
    PlayerData = val
end)

-- Menu-navigation hook: lets a tmg-menu "Go Back" entry reopen the main cityhall menu.
RegisterNetEvent('tmg-cityhall:client:openCityhallMenu', function()
    openCityhallMenu()
end)

-- Menu-navigation hook for the "ID Card" entry; opens the license purchase menu.
RegisterNetEvent('tmg-cityhall:client:openIdentityMenu', function()
    openIdentityMenu()
end)

-- Menu-navigation hook for the "Job Center" entry; opens the job application menu.
RegisterNetEvent('tmg-cityhall:client:openJobMenu', function()
    openJobMenu()
end)

-- Asks the server to hand out the framework's configured starter items (ID card, driver license, etc).
RegisterNetEvent('tmg-cityhall:client:getIds', function()
    TriggerServerEvent('tmg-cityhall:server:getIDs')
end)

-- Handles a license purchase pick. Checks the player is still in a cityhall zone and that the menu's
-- quoted cost matches config, then asks the server to charge and issue the item.
-- The success notification fires optimistically, before the server confirms payment succeeded.
RegisterNetEvent('tmg-cityhall:client:requestId', function(data)
    if inRangeCityhall then
        local license = Config.Cityhalls[closestCityhall].licenses[data.type]
        if license and data.cost == license.cost then
            TriggerServerEvent('tmg-cityhall:server:requestId', data.type, closestCityhall)
            TMGCore.Functions.Notify(('You have received your %s for $%s'):format(license.label, data.cost), 'success', 3500)
        else
            TMGCore.Functions.Notify(Lang:t('error.not_in_range'), 'error')
        end
    else
        TMGCore.Functions.Notify(Lang:t('error.not_in_range'), 'error')
    end
end)

-- Sends the chosen job to the server, passing the cityhall coords the server uses for its distance check.
RegisterNetEvent('tmg-cityhall:client:applyJob', function(data)
    if inRangeCityhall then
        TriggerServerEvent('tmg-cityhall:server:ApplyJob', data.job, Config.Cityhalls[closestCityhall].coords)
    else
        TMGCore.Functions.Notify(Lang:t('error.not_in_range'), 'error')
    end
end)

-- Fired on an online driving instructor's client. After a 2.5-4s delay, sends them an in-game phone
-- mail about the waiting student (charinfo is the student's). Note the salutation gender is read from
-- the local (instructor's) PlayerData, not from the passed-in student charinfo.
RegisterNetEvent('tmg-cityhall:client:sendDriverEmail', function(charinfo)
    SetTimeout(math.random(2500, 4000), function()
        local gender = Lang:t('email.mr')
        if PlayerData.charinfo.gender == 1 then
            gender = Lang:t('email.mrs')
        end
        TriggerServerEvent('tmg-phone:server:sendNewMail', {
            sender = Lang:t('email.sender'),
            subject = Lang:t('email.subject'),
            message = Lang:t('email.message', { gender = gender, lastname = charinfo.lastname, firstname = charinfo.firstname, phone = charinfo.phone }),
            button = {}
        })
    end)
end)

-- Cleans up this resource's blips and spawned peds when it is stopped or restarted.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    deleteBlips()
    deletePeds()
end)

-- Threads

-- Once per second while logged in, refreshes the cached ped/coords and recomputes which cityhall and
-- driving school are closest. Other code reads closestCityhall / closestDrivingSchool from here.
CreateThread(function()
    while true do
        if isLoggedIn then
            playerPed = PlayerPedId()
            playerCoords = GetEntityCoords(playerPed)
            closestCityhall = getClosestHall()
            closestDrivingSchool = getClosestSchool()
        end
        Wait(1000)
    end
end)

-- Startup thread: creates the map blips and peds. When Config.UseTarget is off it then polls for [E]
-- to open the cityhall menu or request a driving test, sleeping 1s unless the player is in range.
CreateThread(function()
    initBlips()
    spawnPeds()
    if not Config.UseTarget then
        while true do
            local sleep = 1000
            if isLoggedIn and closestCityhall and closestDrivingSchool then
                if inRangeCityhall then
                    sleep = 0
                    if IsControlJustPressed(0, 38) then
                        openCityhallMenu()
                        exports['tmg-core']:KeyPressed()
                        Wait(500)
                        exports['tmg-core']:HideText()
                        sleep = 1000
                    end
                elseif inRangeDrivingSchool then
                    sleep = 0
                    if IsControlJustPressed(0, 38) then
                        TriggerServerEvent('tmg-cityhall:server:sendDriverTest', Config.DrivingSchools[closestDrivingSchool].instructors)
                        sleep = 5000
                        exports['tmg-core']:KeyPressed()
                        Wait(500)
                        exports['tmg-core']:HideText()
                    end
                end
            end
            Wait(sleep)
        end
    end
end)
