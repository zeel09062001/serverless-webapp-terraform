// =============================================================================
// API: every call to our backend goes through request().
// It attaches the login token and turns error responses into exceptions.
// =============================================================================

import { getAccessToken, signOut } from "./auth.js";

const API_URL = window.APP_CONFIG.apiUrl;

// A special error type, so the app can tell "please sign in again"
// apart from ordinary errors.
export class SessionExpiredError extends Error { }

async function request(method, path, body) {
    const token = await getAccessToken();

    const headers = { Authorization: `Bearer ${token}` };
    if (body !== undefined) {
        headers["Content-Type"] = "application/json";
    }

    const response = await fetch(API_URL + path, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
    });

    if (response.status === 401) {
        signOut();
        throw new SessionExpiredError("Your session has expired. Please sign in again.");
    }

    if (response.status === 204) {
        return null; // success with no content (e.g. after a delete)
    }

    const data = await response.json().catch(() => null);
    if (!response.ok) {
        // Our Lambda sends {"error": ...}; API Gateway sends {"message": ...}
        throw new Error(data?.error || data?.message || `Request failed (${response.status})`);
    }
    return data;
}

export const listExpenses = (month) =>
    request("GET", `/expenses?month=${encodeURIComponent(month)}`);

export const createExpense = (expense) =>
    request("POST", "/expenses", expense);

export const updateExpense = (id, expense) =>
    request("PUT", `/expenses/${encodeURIComponent(id)}`, expense);

export const deleteExpense = (id) =>
    request("DELETE", `/expenses/${encodeURIComponent(id)}`);