fx_version 'cerulean'
game 'gta5'
lua54 'yes'
use_fxv2_oal 'yes'
author 'TMG_Manic'
description 'Improved Cityhall. Backend structure is now refined.'
version '1.0.0'

shared_scripts {
    '@tmg-core/shared/locale.lua',
    'locales/en.lua',
    'locales/*.lua',
    'config.lua'
}

server_script 'server/main.lua'

client_scripts {
    '@PolyZone/client.lua',
    '@PolyZone/BoxZone.lua',
    'client/main.lua'
}

-- Declares the tmg-core dependency this resource already relies on via
-- exports['tmg-core']:GetCoreObject(). Without it FXServer starts this resource even when
-- tmg-core failed, and it throws "No such export GetCoreObject" at load instead of
-- refusing to start.
dependencies { 'tmg-core' }
