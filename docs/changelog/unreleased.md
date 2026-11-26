# Unreleased

### Fixed

- **Dashboard: a modal opens on the click, not after its request.** Every `useQuery` read suspended the app's route `<Suspense>` until its first response, so opening a retry, dead or process detail swapped the whole page for its skeleton, detached the open `<dialog>` and brought it back non-modal once the request answered: the flicker. Queries no longer suspend (`frontend/src/query.ts`). The job modal shows a backtrace placeholder the size of the backtrace while it loads, and the process modal shows one row per running job. Hovering a row or card fetches its detail ahead. A poll never remounts an open modal.
- **Dashboard: switching pages no longer waits on the new page's data.** The old page stayed on screen, with no sign of loading, until the new page's data arrived. Now a page renders its header and skeleton as soon as its code is there, cached data shows at once and refreshes in the background, and hovering a nav link fetches that page's code and, for Retries, Scheduled, Dead, Busy and Queues, its list. Every page's code also loads while the browser is idle. A click that beats both waits for the page's code, and a bar along the top now shows it registered.

### Changed

- **Dashboard actions apply on the click.** Retry, delete, kill and add-to-queue (one entry, a selection, or all), deleting a queued job, clearing or pausing a queue, pausing a cron loop, and quieting or stopping a process update the list and the counters before the request returns. A failed request puts everything back and raises the error toast. The next poll replaces the estimate. A filtered "all" sweep is unchanged: it still reports progress as it goes.
