local teleportWhenPluginClosed = true
local windowOpen = false

local teleport_button = ac.ControlButton("AdvancedTeleport/Teleport")
local teleport_button_alternate = ac.ControlButton("AdvancedTeleport/TeleportAlternate")
local sim = ac.getSim()
local teleports = {}
local teleportGroups = {}
local selectedGroupHash = nil
local initialized = false
local mapId = nil
local mapHash = nil
local configFile = ac.getFolder(ac.FolderID.ACApps) .. "/lua/AdvancedTeleport/config.ini"

local teleportInProgress = false
local teleportToPitsInProgress = false
local teleportToGroupInProgress = false

local targetTeleport = nil
local availableTeleports = {}
local firstTeleport = nil

local function checkTeleportOccupied(teleport, shouldConsiderCars)
    for i=0, sim.carsCount-1 do
        if shouldConsiderCars[i] and ac.getCar(i).position:distanceSquared(teleport.POS)<(6^2) then
            return true
        end
    end
    return false
end

local function hashMapName(mapName)
    local hash = 0
    for i = 1, #mapName do
        hash = ((hash * 31) + string.byte(mapName, i)) % 1000000
    end
    return "MAP_" .. hash
end

local function hashGroupName(groupName)
    local hash = 0
    for i = 1, #groupName do
        hash = ((hash * 31) + string.byte(groupName, i)) % 1000000
    end
    return "GROUP_" .. hash
end

-- Load teleport points from server configuration
local function loadOnlineTeleports()
    teleports = {}
    teleportGroups = {}
    if not (sim.isOnlineRace and ac.INIConfig.onlineExtras) then
        return
    end
    
    local ini = ac.INIConfig.onlineExtras()
    local teleport_data = {}
    
    -- Parse teleport points from INI file
    for a, b in ini:iterateValues('TELEPORT_DESTINATIONS', 'POINT') do
        local n = tonumber(b:match('%d+')) + 1
        
        if teleport_data[n] == nil then
            for i = #teleport_data, n do
                if teleport_data[i] == nil then teleport_data[i] = {} end
            end
        end
        
        local suffix = b:match('_(%a+)$')
        if suffix == nil then 
            teleport_data[n]['POINT'] = ini:get('TELEPORT_DESTINATIONS', b, 'noname' .. n-1)
        elseif suffix == 'POS' then 
            teleport_data[n]['POS'] = ini:get('TELEPORT_DESTINATIONS', b, vec3())
        elseif suffix == 'HEADING' then 
            teleport_data[n]['HEADING'] = ini:get('TELEPORT_DESTINATIONS', b, 0)
        elseif suffix == 'GROUP' then 
            teleport_data[n]['GROUP'] = ini:get('TELEPORT_DESTINATIONS', b, 'group')
        end
        teleport_data[n]["N"] = n
        teleport_data[n]['INDEX'] = 0
    end
    
    -- Convert to sorted array
    for i = 1, #teleport_data do
        if teleport_data[i]["POINT"] ~= nil then
            teleport_data[i]['INDEX'] = #teleports
            if teleport_data[i].HEADING == nil then teleport_data[i]['HEADING'] = 0 end
            if teleport_data[i].POS == nil then teleport_data[i]['POS'] = vec3() end
            table.insert(teleports, teleport_data[i])
        end
    end
    
    -- Group teleports by GROUP property
    local groupMap = {}
    for _, teleport in ipairs(teleports) do
        local groupName = teleport.GROUP or "Default"
        local groupHash = hashGroupName(groupName)
        
        if not groupMap[groupName] then
            groupMap[groupName] = {
                name = groupName,
                hash = groupHash,
                teleports = {}
            }
        end
        
        -- Add group hash to individual teleport record
        teleport.GROUP_HASH = groupHash
        
        table.insert(groupMap[groupName].teleports, teleport)
    end
    
    -- Convert group map to sorted array
    for groupName, group in pairs(groupMap) do
        table.insert(teleportGroups, group)
    end
    
    -- Sort groups by name
    table.sort(teleportGroups, function(a, b) return a.name < b.name end)
    
    -- Load saved group hash for current map
    local config = ac.INIConfig.load(configFile)
    
    local savedGroupHash = config:get(mapHash, "SELECTED_GROUP_HASH", "")
    
    -- Find the group that matches the saved hash
    selectedGroupHash = nil
    if savedGroupHash ~= "" then
        for _, group in ipairs(teleportGroups) do
            if group.hash == savedGroupHash then
                selectedGroupHash = savedGroupHash
                break
            end
        end
    end
    
    -- Default to first group if no valid saved selection
    if not selectedGroupHash and #teleportGroups > 0 then
        selectedGroupHash = teleportGroups[1].hash
    end
end

local function loadSettings()
    local config = ac.INIConfig.load(configFile)
    
    teleportWhenPluginClosed = config:get("SETTINGS", "TELEPORT_WHEN_PLUGIN_CLOSED", true)
end

local function saveSettings()
    local config = ac.INIConfig.load(configFile)
    config:set("SETTINGS", "TELEPORT_WHEN_PLUGIN_CLOSED", teleportWhenPluginClosed)
    config:save()
end

function script.windowShow()
    windowOpen = true
    -- Always ensure teleports are loaded (in case script was reset)
    local currentMapId = ac.getTrackFullID('/')
    local currentMapHash = hashMapName(currentMapId)
    
    -- Reload teleports if we don't have any or if map changed
    if #teleportGroups == 0 or mapId ~= currentMapId then
        mapId = currentMapId
        mapHash = currentMapHash
        loadOnlineTeleports()
        initialized = true
    end
    
    -- Always reload config when window is shown to restore saved selection
    if mapId and mapHash and #teleportGroups > 0 then
        local config = ac.INIConfig.load(configFile)
        local savedGroupHash = config:get(mapHash, "SELECTED_GROUP_HASH", "")
        
        -- Find the group that matches the saved hash
        selectedGroupHash = nil
        if savedGroupHash ~= "" then
            for _, group in ipairs(teleportGroups) do
                if group.hash == savedGroupHash then
                    selectedGroupHash = savedGroupHash
                    break
                end
            end
        end
        
        -- Default to first group if no valid saved selection
        if not selectedGroupHash and #teleportGroups > 0 then
            selectedGroupHash = teleportGroups[1].hash
        end
    end
    loadSettings()
end

function script.windowMain(dt)
    local shouldConsiderCars = {}
    for j=0, sim.carsCount-1 do
        local car = ac.getCar(j)
        if ((not sim.isReplayOnlyMode) and car.isConnected and (not car.isHidingLabels)) or (sim.isReplayActive and car.isActive) then
            shouldConsiderCars[j] = true
        end
    end

    if selectedGroupHash then
        for _, group in ipairs(teleportGroups) do
            if group.hash == selectedGroupHash then
                local availableCount = 0
                local totalCount = #group.teleports
                for _, teleport in ipairs(group.teleports) do
                    if not checkTeleportOccupied(teleport, shouldConsiderCars) then
                        availableCount = availableCount + 1
                    end
                end
                local displayName = group.name .. ' (' .. availableCount .. '/' .. totalCount .. ' available)'
                if availableCount == 0 then
                    ui.pushStyleColor(ui.StyleColor.Text, rgbm.colors.red)
                end
                ui.text(displayName)
                if availableCount == 0 then
                    ui.popStyleColor()
                end
                break
            end
        end
        ui.newLine(-10)
        ui.separator()
        ui.newLine(-10)
    end

    ui.text('Teleport Button:')
    teleport_button:control()
    ui.newLine(-10)

    ui.separator()
    ui.newLine(-10)
    
    ui.text('Available Teleports:')
    
    if #teleportGroups == 0 then
        if sim.isOnlineRace then
            ui.textColored('No teleport groups available', rgbm.colors.yellow)
        else
            ui.textColored('Not in online race', rgbm.colors.red)
        end
    else
        -- Display teleport groups as radio buttons
        for i, group in ipairs(teleportGroups) do
            local groupName = group.name
            local availableCount = 0
            local totalCount = #group.teleports
            
            -- Count available teleports for display purposes
            
            for _, teleport in ipairs(group.teleports) do
                if not checkTeleportOccupied(teleport, shouldConsiderCars) then
                    availableCount = availableCount + 1
                end
            end
            
            local displayName = groupName .. ' (' .. availableCount .. '/' .. totalCount .. ' available)'
            
            -- Color code based on availability
            if availableCount == 0 then
                ui.pushStyleColor(ui.StyleColor.Text, rgbm.colors.red)
            elseif availableCount < totalCount then
                ui.pushStyleColor(ui.StyleColor.Text, rgbm.colors.yellow)
            end
            
            if ui.radioButton(displayName .. '##' .. i, selectedGroupHash == group.hash) then
                selectedGroupHash = group.hash
    
                -- Ensure mapId and mapHash are initialized
                if not mapId then
                    mapId = ac.getTrackFullID('/')
                    mapHash = hashMapName(mapId)
                end
                
                local config = ac.INIConfig.load(configFile)
                
                config:set(mapHash, "SELECTED_GROUP_HASH", selectedGroupHash)
                config:set(mapHash, "SELECTED_GROUP_NAME", group.name)
                config:set(mapHash, "MAP_NAME", mapId)
                
                local success = config:save()
                if not success then
                    ac.log("AdvancedTeleport: Failed to save config file: " .. configFile)
                end
            end
            
            if availableCount == 0 then
                ui.popStyleColor()
                if ui.itemHovered() then
                    ui.setTooltip('All teleports in this group are blocked')
                end
            elseif availableCount < totalCount then
                ui.popStyleColor()
                if ui.itemHovered() then
                    ui.setTooltip('Some teleports in this group are blocked')
                end
            end
        end
    end
end

local function teleportUpdate()
    -- Update available teleports and first teleport
    availableTeleports = {}
    firstTeleport = nil
    
    if #teleportGroups > 0 then
        local shouldConsiderCars = {}

        for i=0, sim.carsCount-1 do
            local car = ac.getCar(i)
            if ((not sim.isReplayOnlyMode) and car.isConnected and (not car.isHidingLabels)) or (sim.isReplayActive and car.isActive) then
                shouldConsiderCars[i] = true
            end
        end

        -- Calculate available teleports for the selected group
        for _, group in ipairs(teleportGroups) do
            local isSelectedGroup = (selectedGroupHash == group.hash)
            
            for _, teleport in ipairs(group.teleports) do
                if isSelectedGroup and firstTeleport == nil then
                    firstTeleport = teleport
                end

                if not checkTeleportOccupied(teleport, shouldConsiderCars) then
                    if isSelectedGroup then
                        table.insert(availableTeleports, teleport)
                    end
                end
            end
        end
    end
    
    if teleport_button:pressed() or teleport_button_alternate:pressed() then
        if not teleportInProgress then
            teleportInProgress = true
            targetTeleport = availableTeleports[1] or firstTeleport
            if targetTeleport and ac.canTeleportToServerPoint(targetTeleport.INDEX) then
                ac.teleportToServerPoint(targetTeleport.INDEX)
                teleportToGroupInProgress = true
            elseif targetTeleport then
                teleportToPitsInProgress = true
            else
                -- No valid teleport target, cancel the teleport
                teleportInProgress = false
            end
        else
            teleportInProgress = false
            teleportToPitsInProgress = false
            teleportToGroupInProgress = false
            targetTeleport = nil
        end
    end

    if teleportInProgress then
        if teleportToPitsInProgress then
            if ac.tryToTeleportToPits() then
                teleportToPitsInProgress = false
                teleportToGroupInProgress = true
            end
        elseif teleportToGroupInProgress then
            if ac.getCar(0).position:distanceSquared(targetTeleport.POS) < (6^2) then
                teleportInProgress = false
                teleportToGroupInProgress = false
                targetTeleport = nil
            elseif ac.canTeleportToServerPoint(targetTeleport.INDEX) then
                ac.teleportToServerPoint(targetTeleport.INDEX)
            end
        end
    end
end

function script.windowHide()
    windowOpen = false
end

function script.background()
    if not initialized then
        local currentMapId = ac.getTrackFullID('/')
        local currentMapHash = hashMapName(currentMapId)
        
        -- Reload teleports if we don't have any or if map changed
        if #teleportGroups == 0 or mapId ~= currentMapId then
            mapId = currentMapId
            mapHash = currentMapHash
            loadOnlineTeleports()
            initialized = true
        end
        
        -- Always reload config when window is shown to restore saved selection
        if mapId and mapHash and #teleportGroups > 0 then
            local config = ac.INIConfig.load(configFile)
            local savedGroupHash = config:get(mapHash, "SELECTED_GROUP_HASH", "")
            
            -- Find the group that matches the saved hash
            selectedGroupHash = nil
            if savedGroupHash ~= "" then
                for _, group in ipairs(teleportGroups) do
                    if group.hash == savedGroupHash then
                        selectedGroupHash = savedGroupHash
                        break
                    end
                end
            end
            
            -- Default to first group if no valid saved selection
            if not selectedGroupHash and #teleportGroups > 0 then
                selectedGroupHash = teleportGroups[1].hash
            end
        end
        loadSettings()
    end

    if windowOpen or teleportWhenPluginClosed then
        teleportUpdate()
    end
end

function script.windowSettings()
    if ui.checkbox('Teleport when plugin closed', teleportWhenPluginClosed) then
        teleportWhenPluginClosed = not teleportWhenPluginClosed
        saveSettings()
    end
    ui.separator()
    ui.text('Alternate teleport button:')
    teleport_button_alternate:control()
end