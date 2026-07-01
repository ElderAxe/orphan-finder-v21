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

-- Localised alert text for an orphan, distinct for belts and pipes
local function alert_message(entity)
  if entity.type == "underground-belt" then
    return {"orphans.alert-belt"}
  else
    return {"orphans.alert-pipe"}
  end
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
    player.add_custom_alert(entity, alert_icon(entity), alert_message(entity), true)
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

-- Belt is orphan if it has no connected underground partner (a ghost partner does not count).
-- Factorio 2.1 replaced LuaEntity.neighbours with the underground_belt_neighbour property.
local function belt_is_orphan(entity)
  local neighbour = entity.underground_belt_neighbour
  return not (neighbour and neighbour.type == "underground-belt")
end

-- Underground belt gained a partner: remove that partner's marker if it had one
local function update_belt_neighbour(entity)
  local neighbour = entity.underground_belt_neighbour
  if neighbour and neighbour.type == "underground-belt" then
    delete_arrow(neighbour)
  end
end

-- Determine if an underground pipe is an orphan from its fluidbox connection points.
-- Factorio 2.1 replaced LuaEntity.neighbours / LuaFluidBox.get_pipe_connections with
-- LuaEntity.get_fluid_box_pipe_connections, which lists every connection point (a point with
-- a non-nil target is actually connected).
local function pipe_is_orphan(entity)
  local max_underground = 0
  local connected_underground = 0
  for _,conn in pairs(entity.get_fluid_box_pipe_connections(1) or {}) do
    -- Only counting underground connections, we do not care about the surface world
    if conn.connection_type == "underground" then
      max_underground = max_underground + 1
      if conn.target then
        connected_underground = connected_underground + 1
      end
    end
  end
  if max_underground == 0 then
    -- modded pipe has no underground connections therefore can never be an orphan
    return false
  end
  if settings.global["orphan-finder-underground-mode"].value == "strict" then
    -- Strict mode, only considered an orphan if no underground connections
    return connected_underground == 0
  else
    -- Loose mode, considered an orphan if fewer than the maximum underground connections
    return connected_underground < max_underground
  end
end

-- Underground pipe changed: remove markers from any connected underground pipe that is no longer an orphan
local function update_pipe_neighbours(entity)
  for _,conn in pairs(entity.get_fluid_box_pipe_connections(1) or {}) do
    if conn.connection_type == "underground" and conn.target and conn.target.type == "pipe-to-ground" then
      if not pipe_is_orphan(conn.target) then
        delete_arrow(conn.target)
      end
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
      for _,pipe in pairs(pipes) do
        if pipe_is_orphan(pipe) then
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

-- Custom alerts fade after a few seconds unless re-added, so refresh every second while any
-- markers are active. Re-adding the same alert just resets its timer (it does not stack).
script.on_nth_tick(60, function()
  if not storage.arrows then return end
  for player_index, set in pairs(storage.arrows) do
    local player = game.get_player(player_index)
    if player then
      for _, marker in pairs(set) do
        local target = marker.target
        if target and target.valid then
          player.add_custom_alert(target, alert_icon(target), alert_message(target), true)
        end
      end
    end
  end
end)
