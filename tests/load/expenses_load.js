// =============================================================================
// Load test for the expenses API (k6).
// Run against DEV only. Settings come from environment variables:
//   API_URL   the dev API base URL
//   TOKEN     an access token for a dedicated test user
//   RATE      new iterations per second (default 5)
//   DURATION  how long to run (default 2m)
// =============================================================================
import http from "k6/http";
import { check } from "k6";

const API = __ENV.API_URL;
const HEADERS = {
    Authorization: `Bearer ${__ENV.TOKEN}`,
    "Content-Type": "application/json",
};

export const options = {
    scenarios: {
        traffic: {
            // OPEN model: start RATE new iterations every second, no matter how
            // slow responses get, like real users arriving independently.
            executor: "constant-arrival-rate",
            rate: Number(__ENV.RATE || 5),
            timeUnit: "1s",
            duration: __ENV.DURATION || "2m",
            preAllocatedVUs: 20, // "virtual users" ready to send requests
            maxVUs: 100,
        },
    },
    // Pass/fail targets, checked at the end of the run
    thresholds: {
        http_req_failed: ["rate<0.01"], // under 1% of requests fail
        "http_req_duration{kind:read}": ["p(95)<500"], // reads: p95 under 500 ms
        "http_req_duration{kind:write}": ["p(95)<800"], // writes: p95 under 800 ms
    },
};

export default function () {
    // A realistic mix: about 80% of activity is viewing the list
    if (Math.random() < 0.8) {
        const res = http.get(`${API}/expenses?month=2026-10`, {
            headers: HEADERS,
            tags: { kind: "read" },
        });
        check(res, {
            "list: 200": (r) => r.status === 200,
            "list: not throttled": (r) => r.status !== 429,
        });
        return;
    }

    // About 20%: create an expense, then delete it again (cleans up after itself)
    const created = http.post(
        `${API}/expenses`,
        JSON.stringify({
            amountCents: 100,
            category: "other",
            merchant: "Load test",
            date: "2026-10-15",
        }),
        { headers: HEADERS, tags: { kind: "write" } },
    );
    check(created, { "create: 201": (r) => r.status === 201 });

    if (created.status === 201) {
        const id = created.json("expenseId");
        const deleted = http.del(`${API}/expenses/${id}`, null, {
            headers: HEADERS,
            tags: { kind: "write" },
        });
        check(deleted, { "delete: 204": (r) => r.status === 204 });
    }
}