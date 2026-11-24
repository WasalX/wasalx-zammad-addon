## Customer-service window

Direct tickets show the time left in the customer-service window in the ticket
sidebar. The platform's ticket context supplies `service_window_expires_at` as
a UTC ISO 8601 instant, and the sidebar shows it in the agent's time zone. Once
the window has closed, the desktop composer blocks public WhatsApp free text
and says to send an approved template. Internal notes stay available. When the
expiry is missing or unreadable, the sidebar shows nothing and sending is not
blocked. `useWasalxServiceWindow.ts` holds the window state.

## Portal article previews

Article listings show up to 50,000 Unicode codepoints of each body and stop at a
complete grapheme. Full article reads resume at the preview's actual codepoint
length and use the full body's digest to check for changes.

## Email routing retries

Set `WASALX_ROUTING_RETRY_ATTEMPTS` and `WASALX_ROUTING_RETRY_WAIT_SECONDS` in
the Zammad job worker environment and restart the worker after changing either
setting. Both accept positive integers. The attempt limit includes the first run.
The base wait grows with the square of the failed attempt number. See the
[routing job](zammad-package/app/jobs/wasalx_ticket_routing_job.rb) for the cap and defaults.

When routing or its acknowledgement exhausts its attempts, the worker logs
the job, ticket, and source article IDs and records the terminal failure on
the ticket when the source still matches. The internal note uses Arabic when
Zammad's default language is Arabic, and English otherwise. Use the WasalX
action to replay it after resolving the failure.
