local TMGCore = exports['tmg-core']:GetCoreObject()
local availableJobs = Config.AvailableJobs

-- Exports

local function AddCityJob(jobName, toCH)
    if availableJobs[jobName] then return false, 'already added' end
    availableJobs[jobName] = {
        ['label'] = toCH.label,
        ['isManaged'] = toCH.isManaged
    }
    return true, 'success'
end

exports('AddCityJob', AddCityJob)

-- Functions

local function giveStarterItems()
    local Player = TMGCore.Functions.GetPlayer(source)
    if not Player then return end
    for _, v in pairs(TMGCore.Shared.StarterItems) do
        local info = {}
        if v.item == 'id_card' then
            info.citizenid = Player.PlayerData.citizenid
            info.firstname = Player.PlayerData.charinfo.firstname
            info.lastname = Player.PlayerData.charinfo.lastname
            info.birthdate = Player.PlayerData.charinfo.birthdate
            info.gender = Player.PlayerData.charinfo.gender
            info.nationality = Player.PlayerData.charinfo.nationality
        elseif v.item == 'driver_license' then
            info.firstname = Player.PlayerData.charinfo.firstname
            info.lastname = Player.PlayerData.charinfo.lastname
            info.birthdate = Player.PlayerData.charinfo.birthdate
            info.type = 'Class C Driver License'
        end
        exports['tmg-inventory']:AddItem(source, v.item, 1, false, info, 'tmg-cityhall:giveStarterItems')
    end
end

-- Callbacks

TMGCore.Functions.CreateCallback('tmg-cityhall:server:receiveJobs', function(_, cb)
    cb(availableJobs)
end)

TMGCore.Functions.CreateCallback('tmg-cityhall:server:getIdentityData', function(source, cb, hallId)
    local Player = TMGCore.Functions.GetPlayer(source)
    if not Player then return cb({}) end

    local licensesMeta = Player.PlayerData.metadata['licences']
    local availableLicenses = {}

    for license, data in pairs(Config.Cityhalls[hallId].licenses) do
        if not data.metadata or licensesMeta[data.metadata] then
            availableLicenses[license] = data
        end
    end

    cb(availableLicenses)
end)

-- Events

RegisterNetEvent('tmg-cityhall:server:requestId', function(item, hall)
    local src = source
    local Player = TMGCore.Functions.GetPlayer(src)
    if not Player then return end
    local itemInfo = Config.Cityhalls[hall].licenses[item]
    if not Player.Functions.RemoveMoney('cash', itemInfo.cost, 'cityhall id') then return TriggerClientEvent('TMGCore:Notify', src, ('You don\'t have enough money on you, you need %s cash'):format(itemInfo.cost), 'error') end
    local info = {}
    if item == 'id_card' then
        info.citizenid = Player.PlayerData.citizenid
        info.firstname = Player.PlayerData.charinfo.firstname
        info.lastname = Player.PlayerData.charinfo.lastname
        info.birthdate = Player.PlayerData.charinfo.birthdate
        info.gender = Player.PlayerData.charinfo.gender
        info.nationality = Player.PlayerData.charinfo.nationality
    elseif item == 'driver_license' then
        info.firstname = Player.PlayerData.charinfo.firstname
        info.lastname = Player.PlayerData.charinfo.lastname
        info.birthdate = Player.PlayerData.charinfo.birthdate
        info.type = 'Class C Driver License'
    elseif item == 'weaponlicense' then
        info.firstname = Player.PlayerData.charinfo.firstname
        info.lastname = Player.PlayerData.charinfo.lastname
        info.birthdate = Player.PlayerData.charinfo.birthdate
    else
        return false
    end
    if not exports['tmg-inventory']:AddItem(source, item, 1, false, info, 'tmg-cityhall:server:requestId') then return end
    TriggerClientEvent('tmg-inventory:client:ItemBox', src, TMGCore.Shared.Items[item], 'add')
end)

RegisterNetEvent('tmg-cityhall:server:sendDriverTest', function(instructors)
    local src = source
    local Player = TMGCore.Functions.GetPlayer(src)
    if not Player then return end

    local requestData = {
        student_cid = Player.PlayerData.citizenid,
        student_name = Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname,
        phone = Player.PlayerData.charinfo.phone,
        status = 'pending',
        timestamp = os.time()
    }
    
    exports['tmgnosql']:InsertDocument('driving_requests', requestData)

    for i = 1, #instructors do
        local citizenid = instructors[i]
        local SchoolPlayer = TMGCore.Functions.GetPlayerByCitizenId(citizenid)
        
        if SchoolPlayer then
            TriggerClientEvent('tmg-cityhall:client:sendDriverEmail', SchoolPlayer.PlayerData.source, Player.PlayerData.charinfo)
        else
            local mailData = {
                sender = 'Township',
                subject = 'Driving lessons request',
                message = string.format(
                    "Hello,<br><br>We have a new student waiting in the system.<br>Name: <strong>%s</strong><br>Phone: <strong>%s</strong><br><br>Kind regards,<br>Township Los Santos", 
                    requestData.student_name, 
                    requestData.phone
                ),
                button = {}
            }
            exports['tmg-phone']:sendNewMailToOffline(citizenid, mailData)
        end
    end

    print(string.format("^5[TMG]^7 Mainframe: Driver test request logged for %s", Player.PlayerData.citizenid))
    TriggerClientEvent('TMGCore:Notify', src, 'An email has been sent to driving schools, and your request is logged.', 'success', 5000)
end)

RegisterNetEvent('tmg-cityhall:server:ApplyJob', function(job, cityhallCoords)
    local src = source
    local Player = TMGCore.Functions.GetPlayer(src)
    if not Player then return end
    local ped = GetPlayerPed(src)
    local pedCoords = GetEntityCoords(ped)

    local data = {
        ['src'] = src,
        ['job'] = job
    }
    if #(pedCoords - cityhallCoords) >= 20.0 or not availableJobs[job] then
        return false
    end
    local JobInfo = TMGCore.Shared.Jobs[job]
    Player.Functions.SetJob(data.job)
    TriggerClientEvent('TMGCore:Notify', data.src, Lang:t('info.new_job', { job = JobInfo.label }))
end)

RegisterNetEvent('tmg-cityhall:server:getIDs', giveStarterItems)

RegisterNetEvent('TMGCore:Client:UpdateObject', function()
    TMGCore = exports['tmg-core']:GetCoreObject()
end)

-- Commands

TMGCore.Commands.Add('drivinglicense', 'Give a drivers license to someone', { { 'id', 'ID of a person' } }, true, function(source, args)
    local Player = TMGCore.Functions.GetPlayer(source)
    local SearchedPlayer = TMGCore.Functions.GetPlayer(tonumber(args[1]))
    if SearchedPlayer then
        if not SearchedPlayer.PlayerData.metadata['licences']['driver'] then
            for i = 1, #Config.DrivingSchools do
                for id = 1, #Config.DrivingSchools[i].instructors do
                    if Config.DrivingSchools[i].instructors[id] == Player.PlayerData.citizenid then
                        SearchedPlayer.PlayerData.metadata['licences']['driver'] = true
                        SearchedPlayer.Functions.SetMetaData('licences', SearchedPlayer.PlayerData.metadata['licences'])
                        TriggerClientEvent('TMGCore:Notify', SearchedPlayer.PlayerData.source, 'You have passed! Pick up your drivers license at the town hall', 'success', 5000)
                        TriggerClientEvent('TMGCore:Notify', source, ('Player with ID %s has been granted access to a driving license'):format(SearchedPlayer.PlayerData.source), 'success', 5000)
                        break
                    end
                end
            end
        else
            TriggerClientEvent('TMGCore:Notify', source, "Can't give permission for a drivers license, this person already has permission", 'error')
        end
    else
        TriggerClientEvent('TMGCore:Notify', source, 'Player Not Online', 'error')
    end
end)
