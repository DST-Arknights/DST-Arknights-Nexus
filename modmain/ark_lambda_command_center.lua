-- Initial development balance. Source animations keep their native units.
TUNING.ARK_LAMBDA_COMMAND_CENTER = {
    RANGE = 16,
    DAMAGE = 10,
    ATTACK_PERIOD = 0.25,
    STARTUP_TIME = 0.5,
    AIM_TIME = 0.15,
    SLOW_MULT = 0.5,
    SLOW_DURATION = 8,
    BODY_SCALE = 1.5,
    FX_SCALE = 3,
}

local icon_atlas = "images/inventoryimages/ark_lambda_command_center.xml"
RegisterInventoryItemAtlas(icon_atlas, "ark_lambda_command_center.tex")

AddRecipe2("ark_lambda_command_center", {
    Ingredient("minotaurhorn", 1),
    Ingredient("thulecite", 12),
    Ingredient("gears", 6),
    Ingredient("transistor", 6),
    Ingredient("yellowgem", 2),
}, TECH.MAGIC_THREE, {
    placer = "ark_lambda_command_center_placer",
    atlas = icon_atlas,
    image = "ark_lambda_command_center.tex",
    force_hint = true,
}, { "ARK_TECHNOLOGY" })
