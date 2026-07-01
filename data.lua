arrow = util.table.deepcopy(data.raw["arrow"]["orange-arrow-with-circle"])
arrow.name = "orphan-arrow"
arrow.circle_picture =
{
  filename = "__orphan-finder-v21__/graphics/large-orange-circle.png",
  draw_as_glow = true,
  priority = "low",
  width = 64,
  height = 64
}
arrow.arrow_picture.draw_as_glow = true

data:extend({
  arrow,
  {
    type = "custom-input",
    name = "find-orphans",
    key_sequence = "SHIFT + O"
  },
  {
    type = "shortcut",
    name = "orphan-finder-toggle",
    order = "e[orphan-finder]",
    action = "lua",
    toggleable = true,
    -- Links the button to the Shift+O keybind so its tooltip shows the key.
    associated_control_input = "find-orphans",
    -- Base-game pipe-to-ground icon, on theme for "find orphaned undergrounds".
    icon = "__base__/graphics/icons/pipe-to-ground.png",
    icon_size = 64,
    small_icon = "__base__/graphics/icons/pipe-to-ground.png",
    small_icon_size = 64
  }
})