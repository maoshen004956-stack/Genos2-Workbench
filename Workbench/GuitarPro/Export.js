const rhythmValues = [
    [48, 1, 1], [32, 1, 0], [24, 2, 1], [16, 2, 0], [12, 4, 1], [8, 4, 0],
    [6, 8, 1], [4, 8, 0], [3, 16, 1], [2, 16, 0], [1, 32, 0]
];

function exportGuitarPro(json) {
    const input = JSON.parse(json);
    const { model, Settings } = alphaTab;
    const score = new model.Score();
    score.title = input.title;
    const settings = new Settings();
    const unitsPerBar = input.numerator * 32 / input.denominator;
    const totalUnits = unitsPerBar * input.bars;
    const unitAt = tick => Math.round(tick * 8 / input.ppq);
    const markers = new Map(input.markers.map(([tick, label]) => [unitAt(tick) / unitsPerBar, label]));

    for (let index = 0; index < input.bars; index++) {
        const bar = new model.MasterBar();
        bar.timeSignatureNumerator = input.numerator;
        bar.timeSignatureDenominator = input.denominator;
        if (index === 0) bar.tempoAutomations.push(model.Automation.buildTempoAutomation(false, 0, Math.round(input.bpm), 2));
        if (markers.has(index)) {
            const section = new model.Section();
            section.text = markers.get(index);
            section.marker = '';
            bar.section = section;
        }
        score.addMasterBar(bar);
    }

    const chordTrack = Math.max(0, input.tracks.findIndex(track => !track.drum));
    const chordsAt = new Map(input.harmony.map(([tick, chord]) => [unitAt(tick), chord]));

    input.tracks.forEach((source, index) => {
        const track = new model.Track();
        track.name = source.name;
        track.shortName = source.name;
        track.playbackInfo.program = source.program;
        track.playbackInfo.primaryChannel = source.channel;
        track.playbackInfo.secondaryChannel = source.channel;
        const staff = new model.Staff();
        staff.showTablature = false;
        staff.showStandardNotation = true;
        staff.isPercussion = source.drum;
        track.addStaff(staff);
        score.addTrack(track);

        const events = quantizedEvents(source, unitAt, totalUnits);
        const chords = index === chordTrack ? chordsAt : new Map();
        const breakpoints = Array.from(new Set([...events.keys(), ...chords.keys()])).sort((a, b) => a - b);
        let cursor = 0;
        const sounding = new Map();
        const chordIDs = new Map();
        const articulations = new Map();
        function articulation(pitch) {
            if (!articulations.has(pitch)) {
                const drum = new model.InstrumentArticulation(drumName(pitch), drumLine(pitch), pitch,
                    cymbals.has(pitch) ? 57513 : 57508, -1, -1, -1, 1, pitch);
                articulations.set(pitch, track.getOrRegisterPercussionArticulation(drum));
            }
            return articulations.get(pitch);
        }

        for (let index = 0; index < input.bars; index++) {
            const start = index * unitsPerBar;
            const end = start + unitsPerBar;
            const bar = new model.Bar();
            bar.keySignature = input.fifths;
            bar.keySignatureType = input.minor ? 1 : 0;
            bar.clef = source.drum ? model.Clef.Neutral : source.bass ? model.Clef.F4 : model.Clef.G2;
            staff.addBar(bar);
            const voice = new model.Voice();
            bar.addVoice(voice);

            for (let position = start; position < end;) {
                while (cursor < breakpoints.length && breakpoints[cursor] <= position) cursor++;
                const next = Math.min(end, breakpoints[cursor] ?? end);
                const changes = events.get(position);
                if (changes) {
                    for (const pitch of changes.offs) sounding.delete(pitch);
                    for (const note of changes.ons) sounding.set(note.pitch, note);
                }

                for (let beatAt = position; beatAt < next;) {
                    const [length, duration, dots] = rhythmValues.find(([length]) => length <= next - beatAt);
                    const beat = new model.Beat();
                    beat.duration = duration;
                    beat.dots = dots;
                    beat.isEmpty = false;
                    voice.addBeat(beat);

                    const label = chords.get(beatAt);
                    if (label) {
                        if (!chordIDs.has(label)) {
                            const chord = new model.Chord();
                            chord.name = label;
                            chord.showName = true;
                            chord.showDiagram = false;
                            const id = 'h' + chordIDs.size;
                            staff.addChord(id, chord);
                            chordIDs.set(label, id);
                        }
                        beat.chordId = chordIDs.get(label);
                    }

                    for (const event of sounding.values()) {
                        if (source.drum && event.start !== beatAt) continue;
                        const note = new model.Note();
                        if (source.drum) {
                            note.percussionArticulation = articulation(event.pitch);
                        } else {
                            note.octave = Math.floor(event.pitch / 12);
                            note.tone = event.pitch % 12;
                            note.isTieDestination = event.start < beatAt;
                        }
                        note.dynamics = Math.max(0, Math.min(7, Math.round((event.velocity - 15) / 15)));
                        beat.addNote(note);
                    }
                    if (beat.notes.length) beat.dynamics = beat.notes[0].dynamics;
                    beatAt += length;
                }
                position = next;
            }
        }
    });

    score.finish(settings);
    return new alphaTab.exporter.Gp7Exporter().export(score, settings);
}

const cymbals = new Set([42, 44, 46, 49, 51, 52, 53, 55, 57, 59]);
function drumName(pitch) {
    return ({
        35: 'Acoustic Kick Drum', 36: 'Kick Drum', 37: 'Snare', 38: 'Snare', 39: 'Hand Clap',
        40: 'Snare', 41: 'Tom Very Low', 42: 'Charley', 43: 'Tom Very Low', 44: 'Charley',
        45: 'Tom Low', 46: 'Charley', 47: 'Tom Medium', 48: 'Tom High', 49: 'Crash High',
        50: 'Tom Very High', 51: 'Ride', 52: 'China', 53: 'Ride', 54: 'Tambourine', 55: 'Splash',
        56: 'Cowbell Medium', 57: 'Crash Medium', 59: 'Ride', 60: 'Bongo High', 61: 'Bongo Low'
    })[pitch] ?? 'Percussion ' + pitch;
}
function drumLine(pitch) {
    if (pitch === 35 || pitch === 36) return 7;
    if (pitch === 44) return 9;
    if (cymbals.has(pitch)) return -1;
    if (pitch >= 41 && pitch <= 50) return 6 - Math.floor((pitch - 41) / 2);
    return 3;
}

function quantizedEvents(source, unitAt, totalUnits) {
    const active = new Map();
    const pitches = new Map();
    const events = new Map();

    function collect(pitch, from, to, velocity) {
        const start = Math.min(totalUnits - 1, unitAt(from));
        const end = source.drum ? start + 1 : Math.min(totalUnits, Math.max(start + 1, unitAt(to)));
        const list = pitches.get(pitch) || [];
        const previous = list.at(-1);
        if (previous && previous.end > start) previous.end = start;
        list.push({ pitch, start, end, velocity });
        pitches.set(pitch, list);
    }
    for (const [tick, pitch, velocity] of source.notes) {
        const previous = active.get(pitch);
        if (previous) collect(pitch, previous[0], tick, previous[1]);
        if (velocity) active.set(pitch, [tick, velocity]);
        else active.delete(pitch);
    }
    function bucket(tick) {
        if (!events.has(tick)) events.set(tick, { ons: [], offs: [] });
        return events.get(tick);
    }
    for (const notes of pitches.values()) {
        for (const note of notes) {
            if (note.end <= note.start) continue;
            bucket(note.start).ons.push(note);
            if (!source.drum) bucket(note.end).offs.push(note.pitch);
        }
    }
    return events;
}
