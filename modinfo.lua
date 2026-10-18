-- 对不支持的语言兜底到英文（DST 原版 ChooseTranslationTable 只回退到 tbl[1]，
-- 但我们用字典键值而非数字索引，非 en/zh 语言会返回 nil 导致崩溃）
local function T(tbl)
    return ChooseTranslationTable(tbl) or tbl["en"]
end

name = T({
    en = "Arknights: Nexus",
    zh = "源枢"
})
version = "2.10.2"

-- 版本更新说明（由发布脚本自动维护，请勿手动编辑）
local UPDATE_EN = [[
v2.10.2 (2026-10-18)
- Fixed interactive hover tooltips remaining visible after the mouse leaves when keep_on_hover is enabled without attach_to_parent, and they now attach to the correct screen automatically.
- Improved shared tooltip focus and switching, releasing focus when hidden, with support for the Mon3tr description card and keybind settings interaction.
- Adjusted skill hotkey footer padding, Nexus branding, and skill UI contrast.
- Supply Charger startup scans are now staggered.
---
v2.10.1 (2026-10-08)
- Fixed M3 Cocoon Armor durability being reset to zero after a rollback when at full durability.
]]

local UPDATE_ZH = [[
v2.10.2 (2026-10-18)
- 修复交互式悬浮提示在 keep_on_hover 开启且未指定 attach_to_parent 时鼠标离开后仍显示的问题，并自动挂载到所属屏幕。
- 改进共享悬浮提示的焦点与切换管理，隐藏时释放焦点，支持 Mon3tr 描述卡与按键设置交互。
- 调整技能快捷键底部留白、Nexus 品牌展示与技能界面对比度。
- Supply Charger 启动扫描改为错峰执行。
---
v2.10.1 (2026-10-08)
- 修复 M3茧甲在满耐久时回档后耐久被清零的问题。
]]

description = T({
    en = [[Arknights: Nexus is an Arknights-themed expansion and shared framework for Don't Starve Together.
Includes materials, currencies, crafting stations, elite progression, skills, talents, buff icons, and emoticons.

Current version: ]] .. version .. "\n" .. UPDATE_EN .. [[

Issues & Suggestions Feedback Channels:
Issues: https://github.com/DST-Arknights/DST-Arknights-Nexus/issues
Email: tohsakakuro@outlook.com
QQ Group: 666511586
]],
    zh = [[「源枢」是饥荒联机版的明日方舟主题扩展，为系列角色模组提供通用基础机制，并扩展装备与玩法。
包含材料掉落、货币、加工站与训练站、精英化养成、技能、天赋、Buff图标和表情等内容。

当前版本: ]] .. version .. "\n" .. UPDATE_ZH .. [[

需求与建议反馈渠道:
Issues: https://github.com/DST-Arknights/DST-Arknights-Nexus/issues
Email: tohsakakuro@outlook.com
QQ群: 666511586

欢迎大家积极参与!]]
})
author = "让 望月心灵"
forumthread = "https://steamcommunity.com/sharedfiles/filedetails/?id=3677284770"

api_version = 10

dont_starve_compatible = false
reign_of_giants_compatible = false

dst_compatible = true
all_clients_require_mod = true

icon_atlas = "modicon.xml"
icon = "modicon.tex"

priority = 1

server_filter_tags = {"arknights", "明日方舟", "nexus", "源枢", "item", "物品"}

local function Title(opt)
    opt.options = {{ description = "", data = 0 }}
    opt.default = 0
    return opt
end

configuration_options = {{
    name = "language",
    label = T({
        en = "Choose Language",
        zh = "选择语言"
    }),
    hover = T({
        en = "Choose the language of the mod",
        zh = "选择mod的语言"
    }),
    options = {{
        description = T({
            en = "Chinese",
            zh = "中文"
        }),
        data = "zh"
    }, {
        description = T({
            en = "Auto",
            zh = "自动"
        }),
        data = "auto"
    }},
    default = "auto"
}, {
    name = "hand_base_scale",
    label = T({
        en = "Skill Bar Size",
        zh = "技能栏大小"
    }),
    hover = T({
        en = "Adjust the overall skill bar UI scale. 1.2 matches the current standard size.",
        zh = "调整 技能栏 整体缩放。1.2 为当前标准大小"
    }),
    options = {{
        description = T({
            en = "Small (1.0)",
            zh = "较小 (1.0)"
        }),
        data = 1.0
    }, {
        description = T({
            en = "Standard (1.2)",
            zh = "标准 (1.2)"
        }),
        data = 1.2
    }, {
        description = T({
            en = "Large (1.4)",
            zh = "较大 (1.4)"
        }),
        data = 1.4
    }, {
        description = T({
            en = "Extra Large (1.6)",
            zh = "超大 (1.6)"
        }),
        data = 1.6
    }},
    default = 1.2
}, Title({
    name = "mods_compatibility",
    label = T({
        en = "Other Mods Compatibility",
        zh = "其他模组选项"
    }),
}), {
    name = 'amiya_hecheng_collect',
    label = T({
        en = "Amiya Diamond Optimization",
        zh = "阿米娅合成玉 优化"
    }),
    hover = T({
        en = "When enabled, the modded Amiya will no longer occupy extra inventory space when she drops the diamond.",
        zh = "开启后, 模组阿米娅掉落的合成玉不再额外占用背包空间"
    }),
    options = {{
        description = T({
            en = "Enable",
            zh = "开启"
        }),
        data = true
    }, {
        description = T({
            en = "Disable",
            zh = "关闭"
        }),
        data = false
    }},
    default = false
}}
