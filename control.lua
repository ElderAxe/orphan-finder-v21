-- Returns true if the player currently has any active orphan markers
local function has_markers(player_index)
  local set = storage.arrows and storage.arrows[player_index]
  return set ~= nil and next(set) ~= nil
end

-- Keep the shortcut-bar button's toggled state matching whether the player has markers
local function sync_shortcut(player_index)
  local player = game.get_player(player_index)
  if player then
    player.set_shortcut_toggled("orphan-finder-toggle", has_markers(player_index))
  end
end

-- SignalID for an orphan's alert: an item icon matching its type, falling back to a base signal
local function alert_icon(entity)
  local item_name
  if entity.type == "underground-belt" then
    item_name = "underground-belt"
  elseif entity.type == "pipe-to-ground" then
    item_name = "pipe-to-ground"
  end
  if item_name and prototypes.item[item_name] then
    return {type = "item", name = item_name}
  end
  return {type = "virtual", name = "signal-red"}
end

-- Create marker + clickable alert for an orphan, stored in storage.arrows[player_index][entity.unit_number]
local function create_arrow(entity, player_index)
  storage.arrows = storage.arrows or {}
  storage.arrows[player_index] = storage.arrows[player_index] or {}
  storage.arrows[player_index][entity.unit_number] = {
    arrow = entity.surface.create_entity{
      name = "orphan-arrow",
      position = entity.position
    },
    target = entity
  }
  local player = game.get_player(player_index)
  if player then
    -- Clickable alert in the alert list; clicking it focuses the camera on the orphan
    player.add_custom_alert(entity, alert_icon(entity), {"orphans.alert-text"}, true)
  end
end

-- Remove marker + alert for the provided entity, clear it from storage and return true if one was found.
-- Markers are indexed by player first so loop over any players that have marker sets active.
local function delete_arrow(entity)
  storage.arrows = storage.arrows or {}
  for i,_ in pairs(storage.arrows) do
    local marker = storage.arrows[i][entity.unit_number]
    if marker then
      if marker.arrow.valid then marker.arrow.destroy() end
      storage.arrows[i][entity.unit_number] = nil
      local player = game.get_player(i)
      if player and entity.valid then
        player.remove_alert{entity = entity, type = defines.alert_type.custom}
      end
      -- Resolving the last orphan should turn the button off
      sync_shortcut(i)
      return true
    end
  end
  return false
end

-- Remove all markers + alerts belonging to provided player and return true if any were removed
local function clear_arrows(player_index)
  storage.arrows = storage.arrows or {}
  local set = storage.arrows[player_index]
  local destroyed = false
  if set then
    local player = game.get_player(player_index)
    for _,marker in pairs(set) do
      if marker.arrow.valid then marker.arrow.destroy() end
      if player and marker.target and marker.target.valid then
        player.remove_alert{entity = marker.target, type = defines.alert_type.custom}
      end
      destroyed = true
    end
  end
  storage.arrows[player_index] = nil
  sync_shortcut(player_index)
  return destroyed
end

-- Belt is orphan if it has no neighbour or neighbour is still ghost
local function belt_is_orphan(entity)
  return not (entity.neighbours and entity.neighbours.type == "underground-belt")
end

-- Check neighbour of underground belt and remove marker if present
local function update_belt_neighbour(entity)
  if entity.neighbours and entity.neighbours.type == "underground-belt" then
    delete_arrow(entity.neighbours)
  end
end

-- Returns maximum number of underground connections this entity can have
local function max_pipe_connections(entity)
  local count = 0
  for i,connection in pairs(entity.prototype.fluidbox_prototypes[1].pipe_connections) do
    -- Only counting underground connections, we do not care about the surface world
    if connection.connection_type == "underground" then
      count = count + 1
    end
  end
  -- game.print(entity.name..": "..count.." underground connections cached")
  return count
end

-- Rerturns how many underground pipes are actually connected to this entity
local function count_pipe_connections(entity)
  local count = 0
  for i,pipe in pairs(entity.fluidbox.get_pipe_connections(1)) do
    -- Only counting underground connections, we do not care about the surface world
    if pipe.target and pipe.connection_type == "underground" then
      count = count + 1
    end
  end
  return count
end

-- Count connections and compare to max, determine if orphan based on settings
-- Max connections is optional to allow for caching values when searching many pipes
local function pipe_is_orphan(entity, max_connections)
  max_connections = max_connections or max_pipe_connections(entity)
  if max_connections == 0 then
    -- modded pipe has no underground connections therefore can never be an orphan
    return false
  end
  local pipe_count = count_pipe_connections(entity)
  if settings.global["orphan-finder-underground-mode"].value == "strict" then
    -- Strict mode, only considered an orphan if no underground connections
    return pipe_count == 0
  else
    -- Loose mode, considered an orphan if less than maximum underground connections
    return pipe_count < max_connections
  end
end

-- Check neighbours of underground pipe and remove arrow if they are no longer orphans
local function update_pipe_neighbours(entity)
  for i,neighbour in pairs(entity.neighbours[1]) do
    if not pipe_is_orphan(neighbour) then
      delete_arrow(neighbour)
    end
  end
end

-- Toggle orphan detection for a player: clear existing markers, or search and mark orphans.
-- Shared by the Shift+O keybind and the shortcut-bar button so both behave identically.
local function toggle_orphans(player)
  if not player then return end
  local player_index = player.index
  if not clear_arrows(player_index) then
    -- if no markers were found to be removed then we should look for orphans
    local count = 0
    local search_range = tonumber(settings.global["orphan-finder-search-range"].value)
    -- Belts
    local belts = player.surface.find_entities_filtered{
      position = player.position,
      radius = search_range,
      type = "underground-belt"
    }
    for _,belt in pairs(belts) do
      if belt_is_orphan(belt) then
        create_arrow(belt, player_index)
        count = count + 1
      end
    end
    -- Pipes, don't bother if search mode is "none"
    if settings.global["orphan-finder-underground-mode"].value ~= "none" then
      local pipes = player.surface.find_entities_filtered{
        position = player.position,
        radius = search_range,
        type = "pipe-to-ground"
      }
      -- Create cache of max pipe counts so we don't have to count prototype connections again for every single underground pipe in the search area
      local max_cache = {}
      for _,pipe in pairs(pipes) do
        max_cache[pipe.name] = max_cache[pipe.name] or max_pipe_connections(pipe)
        local max_pipes = max_cache[pipe.name]
        if pipe_is_orphan(pipe, max_pipes) then
          create_arrow(pipe, player_index)
          count = count + 1
        end
      end
    end
    -- How many, if any, were found?
    if count == 0 then
      player.print{"orphans.found-none"}
    elseif count == 1 then
      player.print{"orphans.found-one"}
    else
      player.print{"orphans.found-many", count}
    end
  else
    -- markers were found and removed therefore we are not looking for orphans
    player.print{"orphans.markers-cleared"}
  end
  -- Sync the shortcut button: ON iff the player now has markers
  sync_shortcut(player_index)
end

-- Player built entity, does it resolve an orphan?
script.on_event(defines.events.on_built_entity, function(event)
  if event.entity.type == "underground-belt" then
    update_belt_neighbour(event.entity)
  elseif event.entity.type == "pipe-to-ground" then
    update_pipe_neighbours(event.entity)
  end
end)
script.set_event_filter(defines.events.on_built_entity,
{
  {filter = "type", type = "underground-belt"},
  {filter = "type", type = "pipe-to-ground"}
})
-- Robot built entity, does it resolve an orphan?
script.on_event(defines.events.on_robot_built_entity, function(event)
  if event.entity.type == "underground-belt" then
    update_belt_neighbour(event.entity)
  elseif event.entity.type == "pipe-to-ground" then
    update_pipe_neighbours(event.entity)
  end
end)
script.set_event_filter(defines.events.on_robot_built_entity,
{
  {filter = "type", type = "underground-belt"},
  {filter = "type", type = "pipe-to-ground"}
})

-- Player rotated pipe, does this connect it to another?
script.on_event(defines.events.on_player_rotated_entity, function(event)
  if event.entity.type == "pipe-to-ground" then
    update_pipe_neighbours(event.entity)
    if not pipe_is_orphan(event.entity) then
      delete_arrow(event.entity)
    end
  end
end)

-- Player mined entity, remove possible marker
script.on_event(defines.events.on_pre_player_mined_item, function(event)
  delete_arrow(event.entity)
end)
script.set_event_filter(defines.events.on_pre_player_mined_item,
{
  {filter = "type", type = "underground-belt"},
  {filter = "type", type = "pipe-to-ground"}
})
-- Robot mined entity, remove possible marker
script.on_event(defines.events.on_robot_pre_mined, function(event)
  delete_arrow(event.entity)
end)
script.set_event_filter(defines.events.on_robot_pre_mined,
{
  {filter = "type", type = "underground-belt"},
  {filter = "type", type = "pipe-to-ground"}
})
-- Entity died, remove possible marker
script.on_event(defines.events.on_entity_died, function(event)
  delete_arrow(event.entity)
end)
script.set_event_filter(defines.events.on_entity_died,
{
  {filter = "type", type = "underground-belt"},
  {filter = "type", type = "pipe-to-ground"}
})

-- Player left, remove all their markers
script.on_event(defines.events.on_player_left_game, function(event)
  clear_arrows(event.player_index)
end)

-- Player changed surface, remove all their markers (they belonged to the old surface)
script.on_event(defines.events.on_player_changed_surface, function(event)
  clear_arrows(event.player_index)
end)

-- Keybind pressed
script.on_event("find-orphans", function(event)
  toggle_orphans(game.get_player(event.player_index))
end)

-- Shortcut-bar button clicked
script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name == "orphan-finder-toggle" then
    toggle_orphans(game.get_player(event.player_index))
  end
end)

-- Mod/version changed: the marker storage format differs from older versions, so rebuild
-- from scratch — destroy any leftover marker entities and reset per-player button state.
script.on_configuration_changed(function()
  storage.arrows = {}
  for _,surface in pairs(game.surfaces) do
    for _,arrow in pairs(surface.find_entities_filtered{name = "orphan-arrow"}) do
      arrow.destroy()
    end
  end
  for _,player in pairs(game.players) do
    player.set_shortcut_toggled("orphan-finder-toggle", false)
  end
end)
