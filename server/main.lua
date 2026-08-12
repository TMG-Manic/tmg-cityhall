local TMGCore = exports['tmg-core']:GetCoreObject()
local availableJobs = Config.AvailableJobs

-- Exports

-- Registers a job as hireable from the city hall at runtime. `toCH` supplies label and isManaged.
-- Mutates the in-memory availableJobs table only (not persisted). Returns false if already present.
local function AddCityJob(jobName, toCH)
    if availableJobs[jobName] then return false, 'already added' end
    availableJobs[jobName] = {
        ['label'] = toCH.label,
        ['isManaged'] = toCH.isManaged
    }
    return true, 'success'
end

-- Lets other resources add their job to the city hall job list.
exports('AddCityJob', AddCityJob)

-- Functions

-- Grants every TMGCore.Shared.StarterItems entry to the player, filling in identity metadata for
-- id_card and driver_license. Relies on the ambient `source` of the calling event rather than a parameter.
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

-- Returns the full table of city hall hireable jobs to the requesting client.
TMGCore.Functions.CreateCallback('tmg-cityhall:server:receiveJobs', function(_, cb)
    cb(availableJobs)
end)

-- Returns the licenses buyable at cityhall `hallId`, filtered to those the player is eligible for:
-- a license with a `metadata` key is only offered if that flag is set in the player's 'licences' metadata.
TMGCore.Functions.CreateCallback('tmg-cityhall:server:getIdentityData', function(source, cb, hallId)
    local Player = TMGCore.Functions.GetPlayer(source)
    if not Player then return cb({}) end

    -- Was: hallId came from the client and was indexed unchecked, so a bad index errored the
    -- callback out and the client's handler never fired.
    hallId = tonumber(hallId)
    if not hallId or not Config.Cityhalls[hallId] then return cb({}) end

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

-- Charges the player cash for the requested license at cityhall `hall` and gives them the item with the
-- appropriate identity info attached. Validates the hall index, that the player is stood at that hall and
-- that they are eligible for the license, then aborts on insufficient funds or an unrecognised item type.
RegisterNetEvent('tmg-cityhall:server:requestId', function(item, hall)
    local src = source
    local Player = TMGCore.Functions.GetPlayer(src)
    if not Player then return end
    -- Was: the client-supplied hall index was indexed straight into Config.Cityhalls, there was no
    -- proximity check, and the metadata gate getIdentityData applies was never re-applied, so the
    -- menu's eligibility filter (e.g. having passed the driving test) could simply be skipped.
    local hallId = tonumber(hall)
    local hallConfig = hallId and Config.Cityhalls[hallId]
    if not hallConfig then return end
    local itemInfo = hallConfig.licenses[item]
    if not itemInfo then return end
    if #(GetEntityCoords(GetPlayerPed(src)) - hallConfig.coords) >= 20.0 then
        return TriggerClientEvent('TMGCore:Notify', src, Lang:t('error.not_in_range'), 'error')
    end
    local licensesMeta = Player.PlayerData.metadata['licences']
    if itemInfo.metadata and not (licensesMeta and licensesMeta[itemInfo.metadata]) then
        return TriggerClientEvent('TMGCore:Notify', src, ('You are not eligible for a %s'):format(itemInfo.label), 'error')
    end
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

-- True if `citizenid` is listed as an instructor at any Config.DrivingSchools entry.
local function IsDrivingInstructor(citizenid)
    for i = 1, #Config.DrivingSchools do
        local schoolInstructors = Config.DrivingSchools[i].instructors
        for id = 1, #schoolInstructors do
            if schoolInstructors[id] == citizenid then return true end
        end
    end
    return false
end

-- Logs a driving-lesson request into the 'driving_requests' collection, then notifies each instructor
-- citizenid in `instructors`: online ones get a client email event, offline ones get an offline phone mail.
RegisterNetEvent('tmg-cityhall:server:sendDriverTest', function(instructors)
    local src = source
    local Player = TMGCore.Functions.GetPlayer(src)
    if not Player then return end

    -- Was: the citizenid list came straight from the client, so a crafted event could mail any
    -- player it liked. Only citizenids that are actually configured instructors are notified.
    if type(instructors) ~= 'table' then return end

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

        if not IsDrivingInstructor(citizenid) then
            print(string.format("^1[TMG]^7 Security: Terminal %s tried to mail non-instructor [%s] a lesson request", tostring(src), tostring(citizenid)))
        else
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
    end

    print(string.format("^5[TMG]^7 Mainframe: Driver test request logged for %s", Player.PlayerData.citizenid))
    TriggerClientEvent('TMGCore:Notify', src, 'An email has been sent to driving schools, and your request is logged.', 'success', 5000)
end)

-- Sets the player's job if they are within 20.0 units of a configured cityhall and the job is
-- in availableJobs.
RegisterNetEvent('tmg-cityhall:server:ApplyJob', function(job, _cityhallCoords)
    local src = source
    local Player = TMGCore.Functions.GetPlayer(src)
    if not Player then return end
    local ped = GetPlayerPed(src)
    local pedCoords = GetEntityCoords(ped)

    local data = {
        ['src'] = src,
        ['job'] = job
    }
    -- Was: measured against the client-supplied cityhallCoords, so the range check was advisory
    -- only; now measured against the halls the server knows about.
    local atCityhall = false
    for i = 1, #Config.Cityhalls do
        if #(pedCoords - Config.Cityhalls[i].coords) < 20.0 then
            atCityhall = true
            break
        end
    end
    if not atCityhall or not availableJobs[job] then
        return false
    end
    local JobInfo = TMGCore.Shared.Jobs[job]
    Player.Functions.SetJob(data.job)
    TriggerClientEvent('TMGCore:Notify', data.src, Lang:t('info.new_job', { job = JobInfo.label }))
end)

-- Client-triggered hand-out of the starter item set.
RegisterNetEvent('tmg-cityhall:server:getIDs', giveStarterItems)

-- Re-fetches the core object after tmg-core restarts so cached references stay valid.
RegisterNetEvent('TMGCore:Client:UpdateObject', function()
    TMGCore = exports['tmg-core']:GetCoreObject()
end)

-- Commands

-- /drivinglicense <id> - a registered driving instructor marks the target player as having passed by
-- setting metadata.licences.driver = true. The target must then buy the actual item at a city hall.
-- Open to any player; authorisation comes from the caller's citizenid appearing in Config.DrivingSchools.
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
