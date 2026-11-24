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
