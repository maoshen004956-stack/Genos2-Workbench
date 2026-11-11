function exportMusicXML(json) {
    const input = JSON.parse(json);
    const barLength = input.numerator * 32 / input.denominator;
    const unitAt = tick => Math.round(tick * 8 / input.ppq);
    const xml = ['<?xml version="1.0" encoding="UTF-8"?><score-partwise version="4.0"><part-list>'];
    const escape = text => text.replace(/[<>&]/g, char => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;' })[char]);
    const type = {1: 'whole', 2: 'half', 4: 'quarter', 8: 'eighth', 16: '16th', 32: '32nd'};
    const pitchSteps = input.fifths < 0 ? 'CDDEEFGGAABB' : 'CCDDEFFGGAAB';
    const pitchAlters = input.fifths < 0 ? [0,-1,0,-1,0,0,-1,0,-1,0,-1,0] : [0,1,0,1,0,0,1,0,1,0,1,0];
    const sharpOrder = 'FCGDAEB', flatOrder = 'BEADGCF';
    const signature = (input.fifths < 0 ? flatOrder : sharpOrder).slice(0, Math.abs(input.fifths));
    const pitchNames = 'CDEFGAB', pitchClasses = [0, 2, 4, 5, 7, 9, 11];

    function pitched(midi) {
        const pc = midi % 12;
        let step = pitchSteps[pc], alter = pitchAlters[pc];
        for (const name of signature) {
            const offset = Math.sign(input.fifths);
            if ((pitchClasses[pitchNames.indexOf(name)] + offset + 12) % 12 === pc) {
                step = name;
                alter = offset;
                break;
            }
        }
        return `<pitch><step>${step}</step>${alter ? `<alter>${alter}</alter>` : ''}<octave>${Math.floor((midi - alter) / 12) - 1}</octave></pitch>`;
    }

    input.tracks.forEach((track, index) => {
        const id = `P${index + 1}`;
        const drums = track.drum ? [...new Set(track.notes.map(note => note[1]))] : [];
        xml.push(`<score-part id="${id}"><part-name>${escape(track.name)}</part-name>`);
        if (track.drum) {
            for (const pitch of drums) xml.push(`<score-instrument id="${id}-I${pitch}"><instrument-name>${escape(drumName(pitch))}</instrument-name></score-instrument>`);
            for (const pitch of drums) xml.push(`<midi-instrument id="${id}-I${pitch}"><midi-channel>10</midi-channel><midi-unpitched>${pitch + 1}</midi-unpitched></midi-instrument>`);
        } else {
            xml.push(`<score-instrument id="${id}-I"><instrument-name>${escape(track.name)}</instrument-name></score-instrument>`,
                `<midi-instrument id="${id}-I"><midi-channel>${track.channel + 1}</midi-channel><midi-program>${track.program + 1}</midi-program></midi-instrument>`);
        }
        xml.push('</score-part>');
    });
    xml.push('</part-list>');

    input.tracks.forEach((track, index) => {
        const id = `P${index + 1}`;
        const events = quantizedEvents(track, unitAt, barLength * input.bars);
        const positions = [...events.keys()].sort((a, b) => a - b);
        const sounding = new Map();
        const clef = track.drum ? '<sign>percussion</sign>' : track.bass ? '<sign>F</sign><line>4</line>' : '<sign>G</sign><line>2</line>';
        let cursor = 0;
        xml.push(`<part id="${id}">`);
        for (let bar = 0; bar < input.bars; bar++) {
            const start = bar * barLength;
            const end = start + barLength;
            xml.push(`<measure number="${bar + 1}">`);
            if (bar === 0) {
                const key = track.drum && index !== 0 ? '' : `<key><fifths>${input.fifths}</fifths><mode>${input.minor ? 'minor' : 'major'}</mode></key>`;
                xml.push(`<attributes><divisions>8</divisions>${key}<time><beats>${input.numerator}</beats><beat-type>${input.denominator}</beat-type></time><clef>${clef}</clef></attributes>`);
                if (index === 0) xml.push(`<direction placement="above"><direction-type><metronome><beat-unit>quarter</beat-unit><per-minute>${input.bpm}</per-minute></metronome></direction-type><sound tempo="${input.bpm}"/></direction>`);
            }
            for (let position = start; position < end;) {
                while (cursor < positions.length && positions[cursor] <= position) cursor++;
                const next = Math.min(end, positions[cursor] ?? end);
                const event = events.get(position);
                if (event) {
                    for (const pitch of event.offs) sounding.delete(pitch);
                    if (!track.drum) for (const note of event.ons) sounding.set(note.pitch, note);
                }
                const notes = track.drum ? (event?.ons ?? []) : [...sounding.values()];
                if (notes.length === 0 && position === start && next === end) {
                    xml.push(`<note><rest measure="yes"/><duration>${barLength}</duration><voice>1</voice></note>`);
                } else for (let at = position; at < next;) {
                    const played = track.drum && at !== position ? [] : notes;
                    const maximum = track.drum && played.length ? Math.min(4, next - at) : next - at;
                    const [length, duration, dots] = rhythmValues.find(([length]) => length <= maximum);
                    const rhythm = `<duration>${length}</duration>`;
                    const notation = `<voice>1</voice><type>${type[duration]}</type>${'<dot/>'.repeat(dots)}`;
                    if (played.length === 0) xml.push(`<note><rest/>${rhythm}${notation}</note>`);
                    else played.forEach((note, n) => {
                        const chord = n ? '<chord/>' : '';
                        if (track.drum) {
                            const display = ['C5','A4','F4','D4','B3','G3'][Math.max(0, Math.min(5, Math.round((drumLine(note.pitch) + 1) / 2)))];
                            const head = cymbals.has(note.pitch) ? '<notehead>x</notehead>' : '';
                            xml.push(`<note>${chord}<unpitched><display-step>${display[0]}</display-step><display-octave>${display[1]}</display-octave></unpitched>${rhythm}<instrument id="${id}-I${note.pitch}"/>${notation}${head}</note>`);
                        } else {
                            const ties = [];
                            if (note.start < at) ties.push('stop');
                            if (note.end > at + length) ties.push('start');
                            const sound = ties.map(tie => `<tie type="${tie}"/>`).join('');
                            const marks = ties.length ? `<notations>${ties.map(tie => `<tied type="${tie}"/>`).join('')}</notations>` : '';
                            xml.push(`<note>${chord}${pitched(note.pitch)}${rhythm}${sound}${notation}${marks}</note>`);
                        }
                    });
                    at += length;
                }
                position = next;
            }
            xml.push('</measure>');
        }
        xml.push('</part>');
    });
    xml.push('</score-partwise>');
    return xml.join('');
}
