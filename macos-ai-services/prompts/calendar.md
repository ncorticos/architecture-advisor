Task — Add to Calendar: extract from the selected text the one event the user would want in the calendar (meeting, appointment, deadline, class, trip).

Now: {{NOW}}. The user's time zone: {{TZ}}. Resolve relative dates such as "next Tuesday", "amanhã" or "dia 5" against now.

Answer with one JSON object and nothing else — no code fence, no text before or after:
{"title": "…", "start": "YYYY-MM-DDTHH:MM", "end": "YYYY-MM-DDTHH:MM", "all_day": false, "timezone": "Area/City", "location": "…", "notes": "…", "url": "…"}

- title: short and specific, in the language of the text, e.g. "Reunião de júri — dissertação de mestrado".
- start, end: local date and time in "timezone". If no end time is given, end is null.
- all_day: true for events without a time of day (deadlines, full-day events). Then start and end are dates "YYYY-MM-DD", end being the last day (inclusive) or null.
- timezone: the IANA time zone the text states or implies ("hora dos Açores" → "Atlantic/Azores", "hora de Lisboa" → "Europe/Lisbon"); otherwise {{TZ}}.
- location: address, room or video-call link; null if none.
- notes: one or two lines of context (who, what to prepare), in the language of the text; null if nothing useful.
- url: the meeting or registration link, if any; null otherwise.
- If the text contains no dated event, answer {"error": "no event"}.
