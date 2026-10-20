// =============================================================================
// APP: everything about the page. Forms, the expense list, switching views.
// Never uses innerHTML with data: all text goes in via textContent.
// =============================================================================

import * as auth from "./auth.js";
import * as api from "./api.js";

const $ = (id) => document.getElementById(id);

let pendingEmail = null; // the email waiting for verification
let editingId = null;    // the expense being edited, or null when adding
let expenses = [];       // the expenses currently shown
const RECEIPT_TYPES = ["image/jpeg", "image/png", "application/pdf"];
const MAX_RECEIPT_BYTES = 5 * 1024 * 1024; // 5 MB, same limit as the server
const processingIds = new Set(); // expenses whose receipt is being checked

// -----------------------------------------------------------------------------
// Small helpers
// -----------------------------------------------------------------------------
function showMessage(text, type = "error") {
    const box = $("message");
    box.textContent = text;
    box.className = `message ${type}`;
    box.hidden = false;
}

function clearMessage() {
    $("message").hidden = true;
}

function handleError(error) {
    if (error instanceof api.SessionExpiredError) {
        showAuthView();
    }
    showMessage(error.message || "Something went wrong");
}

// "12.50" -> 1250, without ever using floating-point maths.
// Returns null if the text isn't a valid amount.
function toCents(text) {
    const value = text.trim();
    if (!/^\d+(\.\d{1,2})?$/.test(value)) {
        return null;
    }
    const [whole, fraction = ""] = value.split(".");
    return Number(whole) * 100 + Number(fraction.padEnd(2, "0"));
}

function formatMoney(cents, currency = "USD") {
    return new Intl.NumberFormat(undefined, { style: "currency", currency }).format(cents / 100);
}

function pad(number) {
    return String(number).padStart(2, "0");
}

function currentMonth() {
    const now = new Date();
    return `${now.getFullYear()}-${pad(now.getMonth() + 1)}`;
}

function today() {
    const now = new Date();
    return `${currentMonth()}-${pad(now.getDate())}`;
}

// Wires up a form: prevents page reload, disables the button while working,
// and shows any error. Each form only needs to describe its own logic.
function onSubmit(formId, handler) {
    const form = $(formId);
    form.addEventListener("submit", async (event) => {
        event.preventDefault();
        clearMessage();
        const button = form.querySelector('button[type="submit"]');
        button.disabled = true;
        try {
            await handler(form.elements, form);
        } catch (error) {
            handleError(error);
        } finally {
            button.disabled = false;
        }
    });
}

// -----------------------------------------------------------------------------
// Switching between the signed-out and signed-in views
// -----------------------------------------------------------------------------
function showAuthForm(formId) {
    for (const id of ["sign-in-form", "sign-up-form", "confirm-form"]) {
        $(id).hidden = id !== formId;
    }
}

function showAuthView(formId = "sign-in-form") {
    $("app-view").hidden = true;
    $("user-info").hidden = true;
    $("auth-view").hidden = false;
    showAuthForm(formId);
}

async function showAppView() {
    const email = await auth.getSignedInEmail();
    if (!email) {
        showAuthView();
        return;
    }
    $("auth-view").hidden = true;
    $("app-view").hidden = false;
    $("user-info").hidden = false;
    $("user-email").textContent = email;
    resetExpenseForm();
    await loadExpenses();
}

// -----------------------------------------------------------------------------
// Expenses: load, display, add, edit, delete
// -----------------------------------------------------------------------------
async function loadExpenses() {
    try {
        const data = await api.listExpenses($("month").value);
        expenses = data.expenses;
        renderExpenses();
    } catch (error) {
        handleError(error);
    }
}

function makeButton(label, onClick) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "link";
    button.textContent = label;
    button.addEventListener("click", onClick);
    return button;
}

function renderExpenses() {
    const rows = $("expense-rows");
    rows.replaceChildren(); // clear the old rows

    let totalCents = 0;
    for (const expense of expenses) {
        totalCents += expense.amountCents;

        const row = document.createElement("tr");
        const cells = [
            [expense.date, ""],
            [expense.merchant, ""],
            [expense.category, ""],
            [formatMoney(expense.amountCents, expense.currency), "num"],
        ];
        for (const [text, className] of cells) {
            const cell = document.createElement("td");
            cell.textContent = text; // ALWAYS textContent: user data is never HTML
            cell.className = className;
            row.appendChild(cell);
        }
        if (expense.note) {
            row.children[1].title = expense.note; // shows the note on hover
        }

        row.appendChild(renderReceiptCell(expense));

        const actions = document.createElement("td");
        actions.className = "row-actions";
        actions.append(
            makeButton("Edit", () => startEditing(expense)),
            makeButton("Delete", () => removeExpense(expense)),
        );
        row.appendChild(actions);
        rows.appendChild(row);
    }

    $("empty").hidden = expenses.length > 0;
    $("total").textContent = `Total: ${formatMoney(totalCents)} across ${expenses.length} expense(s)`;
}

// -----------------------------------------------------------------------------
// Receipts: upload, background check, view
// -----------------------------------------------------------------------------
const STATUS_LABELS = {
    NONE: "",
    ATTACHED: "Attached",
    REJECTED: "Rejected",
};

function renderReceiptCell(expense) {
    const cell = document.createElement("td");
    cell.className = "receipt-cell";

    if (processingIds.has(expense.expenseId)) {
        const status = document.createElement("span");
        status.className = "status";
        status.textContent = "Checking…";
        cell.appendChild(status);
        return cell;
    }

    const receiptStatus = expense.receiptStatus || "NONE";
    if (STATUS_LABELS[receiptStatus]) {
        const status = document.createElement("span");
        status.className = `status status-${receiptStatus.toLowerCase()}`;
        status.textContent = STATUS_LABELS[receiptStatus];
        cell.appendChild(status);
    }

    if (receiptStatus === "ATTACHED") {
        cell.appendChild(makeButton("View", () => viewReceipt(expense)));
    }
    const uploadLabel = receiptStatus === "ATTACHED" ? "Replace" : "Upload";
    cell.appendChild(makeButton(uploadLabel, () => uploadReceipt(expense)));
    return cell;
}

// Opens the system file picker and resolves with the chosen file (or null)
function pickFile() {
    return new Promise((resolve) => {
        const input = document.createElement("input");
        input.type = "file";
        input.accept = RECEIPT_TYPES.join(",");
        input.addEventListener("change", () => resolve(input.files[0] || null));
        input.addEventListener("cancel", () => resolve(null));
        input.click();
    });
}

// The worker runs in the background, so we POLL: ask every 2 seconds
// whether the expense's receiptCheckedAt has changed, for up to 20 seconds.
async function waitForReceiptCheck(expenseId, previousCheck) {
    for (let attempt = 0; attempt < 10; attempt += 1) {
        await new Promise((resolve) => setTimeout(resolve, 2000));
        const expense = await api.getExpense(expenseId);
        if (expense.receiptCheckedAt && expense.receiptCheckedAt !== previousCheck) {
            return expense;
        }
    }
    return null; // still not checked: tell the user, don't wait forever
}

async function uploadReceipt(expense) {
    const file = await pickFile();
    if (!file) {
        return;
    }
    clearMessage();

    // Quick checks for a friendly message. NOT security: the server and the
    // worker enforce the real rules, whatever the browser does.
    if (!RECEIPT_TYPES.includes(file.type)) {
        showMessage("Receipts must be JPEG, PNG or PDF files.");
        return;
    }
    if (file.size > MAX_RECEIPT_BYTES) {
        showMessage("That file is too large (max 5 MB).");
        return;
    }

    processingIds.add(expense.expenseId);
    renderExpenses();

    try {
        const { upload } = await api.requestReceiptUpload(expense.expenseId, file.type);
        await api.uploadToS3(upload, file);

        const checked = await waitForReceiptCheck(expense.expenseId, expense.receiptCheckedAt);
        if (!checked) {
            showMessage("Receipt uploaded. It's still being checked, so refresh in a moment.", "info");
        } else if (checked.receiptStatus === "ATTACHED") {
            showMessage("Receipt attached.", "success");
        } else {
            showMessage("That file isn't a valid JPEG, PNG or PDF, so it was rejected.");
        }
    } catch (error) {
        handleError(error);
    } finally {
        processingIds.delete(expense.expenseId);
        if (!$("app-view").hidden) {
            await loadExpenses();
        }
    }
}

async function viewReceipt(expense) {
    // Open the tab NOW, while we're still inside the click, because pop-up
    // blockers only allow new tabs as a direct response to a click.
    // The address is filled in once we have the signed link.
    const tab = window.open("", "_blank");
    if (!tab) {
        showMessage("Please allow pop-ups for this site to view receipts.");
        return;
    }
    tab.opener = null; // the new tab can't reach back into our page (anti-tabnabbing)

    try {
        const { url } = await api.getReceiptLink(expense.expenseId);
        tab.location = url;
    } catch (error) {
        tab.close();
        handleError(error);
    }
}

function readExpenseForm(fields) {
    const amountCents = toCents(fields.amount.value);
    if (amountCents === null || amountCents <= 0) {
        throw new Error("Enter an amount like 12.50");
    }
    const expense = {
        amountCents,
        date: fields.date.value,
        category: fields.category.value,
        merchant: fields.merchant.value.trim(),
    };
    const note = fields.note.value.trim();
    if (note) {
        expense.note = note;
    }
    return expense;
}

function startEditing(expense) {
    const fields = $("expense-form").elements;
    editingId = expense.expenseId;
    fields.amount.value = (expense.amountCents / 100).toFixed(2);
    fields.date.value = expense.date;
    fields.category.value = expense.category;
    fields.merchant.value = expense.merchant;
    fields.note.value = expense.note || "";
    $("form-title").textContent = "Edit expense";
    $("expense-form").querySelector('button[type="submit"]').textContent = "Save changes";
    $("cancel-edit").hidden = false;
    $("expense-form").scrollIntoView({ behavior: "smooth" });
}

function resetExpenseForm() {
    editingId = null;
    $("expense-form").reset();
    $("expense-form").elements.date.value = today();
    $("form-title").textContent = "Add expense";
    $("expense-form").querySelector('button[type="submit"]').textContent = "Add expense";
    $("cancel-edit").hidden = true;
}

async function removeExpense(expense) {
    const label = `${expense.merchant} (${formatMoney(expense.amountCents, expense.currency)})`;
    if (!window.confirm(`Delete ${label}?`)) {
        return;
    }
    try {
        await api.deleteExpense(expense.expenseId);
        if (editingId === expense.expenseId) {
            resetExpenseForm();
        }
        await loadExpenses();
        showMessage("Expense deleted", "success");
    } catch (error) {
        handleError(error);
    }
}

onSubmit("expense-form", async (fields) => {
    const expense = readExpenseForm(fields);
    if (editingId) {
        await api.updateExpense(editingId, expense);
        showMessage("Expense updated", "success");
    } else {
        await api.createExpense(expense);
        showMessage("Expense added", "success");
    }
    $("month").value = expense.date.slice(0, 7); // show the month we just saved into
    resetExpenseForm();
    await loadExpenses();
});

$("cancel-edit").addEventListener("click", resetExpenseForm);
$("month").addEventListener("change", loadExpenses);

// -----------------------------------------------------------------------------
// Sign in, sign up, verify, sign out
// -----------------------------------------------------------------------------
function goToVerification(email) {
    pendingEmail = email;
    $("confirm-email").textContent = email;
    showAuthForm("confirm-form");
}

onSubmit("sign-in-form", async (fields, form) => {
    const email = fields.email.value.trim();
    try {
        await auth.signIn(email, fields.password.value);
    } catch (error) {
        if (error.code === "UserNotConfirmedException") {
            goToVerification(email);
            showMessage("Please verify your email first.", "info");
            return;
        }
        throw error;
    }
    form.reset();
    await showAppView();
});

onSubmit("sign-up-form", async (fields, form) => {
    const email = fields.email.value.trim();
    await auth.signUp(email, fields.password.value);
    form.reset();
    goToVerification(email);
    showMessage("Account created. Check your email for the verification code.", "success");
});

onSubmit("confirm-form", async (fields, form) => {
    await auth.confirmSignUp(pendingEmail, fields.code.value.trim());
    form.reset();
    showAuthForm("sign-in-form");
    $("sign-in-form").elements.email.value = pendingEmail;
    showMessage("Email verified. You can sign in now.", "success");
});

$("resend-code").addEventListener("click", async () => {
    try {
        await auth.resendCode(pendingEmail);
        showMessage("A new code is on its way.", "info");
    } catch (error) {
        handleError(error);
    }
});

for (const link of document.querySelectorAll("[data-show]")) {
    link.addEventListener("click", () => {
        clearMessage();
        showAuthForm(link.dataset.show);
    });
}

$("sign-out").addEventListener("click", () => {
    auth.signOut();
    expenses = [];
    $("expense-rows").replaceChildren(); // remove the previous user's rows
    $("total").textContent = "";
    $("user-email").textContent = "";
    resetExpenseForm(); // clear any half-edited expense
    showAuthView();
    showMessage("You have been signed out.", "info");
});

// -----------------------------------------------------------------------------
// Start: show the app if already signed in, otherwise the sign-in form
// -----------------------------------------------------------------------------
$("month").value = currentMonth();
showAppView();