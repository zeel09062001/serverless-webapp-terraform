// Reads the configuration that Terraform generated and shows it on the page.
const config = window.APP_CONFIG;
const list = document.getElementById("config");

if (!config) {
    list.textContent = "config.js did not load";
} else {
    for (const [key, value] of Object.entries(config)) {
        const item = document.createElement("li");
        // textContent (not innerHTML) treats the value as plain text, never as HTML.
        item.textContent = `${key}: ${value}`;
        list.appendChild(item);
    }
}