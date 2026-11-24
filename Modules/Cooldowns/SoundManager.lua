local addonName, SpellStyler = ...
SpellStyler.SoundManager = SpellStyler.SoundManager or {}
local SoundManager = SpellStyler.SoundManager
SoundManager._mutedSounds = SoundManager._mutedSounds or {}

local function SoundKey(soundID)
    return type(soundID) .. ":" .. tostring(soundID)
end

local function AddSoundIDs(target, sounds)
    if type(sounds) ~= "table" then
        if sounds ~= nil then target[sounds] = true end
        return
    end
    for _, soundID in ipairs(sounds) do
        target[soundID] = true
    end
end

local function GetSoundIDs(soundMeta)
    local soundIDs = {}
    if type(soundMeta) ~= "table" then return soundIDs end

    AddSoundIDs(soundIDs, soundMeta.manuallyMutedSounds)
    return soundIDs
end

local function GetSoundMeta(trackerConfig)
    return trackerConfig and trackerConfig.sound or trackerConfig
end

function SoundManager:MuteTrackerSounds(trackerConfig)
    DevTool:AddData({
        muteValues = GetSoundIDs(GetSoundMeta(trackerConfig)),
        tracker = trackerConfig
    }, "muting: ")
    self:MuteSounds(GetSoundIDs(GetSoundMeta(trackerConfig)))
end

function SoundManager:UnmuteTrackerSounds(trackerConfig)
    self:UnmuteSounds(GetSoundIDs(GetSoundMeta(trackerConfig)))
end

function SoundManager:RefreshTrackerSounds(trackerConfig, previousSoundMeta)
    if previousSoundMeta then
        self:UnmuteTrackerSounds(previousSoundMeta)
    end
    self:MuteTrackerSounds(trackerConfig)
end

function SoundManager:UnmuteSounds(soundIDs)
    if type(soundIDs) ~= "table" then return end
    for soundID in pairs(soundIDs) do
        UnmuteSoundFile(soundID)
        self._mutedSounds[SoundKey(soundID)] = nil
    end
end

function SoundManager:MuteSounds(soundIDs)
    if type(soundIDs) ~= "table" then return end
    for soundID in pairs(soundIDs) do
        MuteSoundFile(soundID)
        self._mutedSounds[SoundKey(soundID)] = soundID
    end
end

function SoundManager:IsSoundMuted(soundID)
    return self._mutedSounds[SoundKey(soundID)] ~= nil
end

function SoundManager:PlaySound(soundMeta, currentSpellID, trigger)
    local sound = soundMeta and (
        soundMeta[currentSpellID] or soundMeta[tostring(currentSpellID)]
    )
    if not sound or sound.trigger ~= trigger
        or sound.targetSoundPath == nil or sound.targetSoundPath == "" then
        return
    end

    local function playNow()
        PlaySoundFile(sound.targetSoundPath, sound.channel or "Master")
    end
    if (sound.delay or 0) > 0 then
        C_Timer.After(sound.delay, playNow)
    else
        playNow()
    end
end
