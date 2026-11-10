// Shows the copy button beside each Homebrew command. Without this script the
// button stays hidden, and a click on the command still selects all of it.

if (navigator.clipboard) {
  for (const button of document.querySelectorAll(".copy")) {
    const command = button.closest(".command");
    const code = command.querySelector("code");
    const status = command.querySelector(".status");
    let timer;

    button.hidden = false;
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(code.textContent);
      } catch {
        // The browser refused, so select the command for a Command-C instead.
        getSelection().selectAllChildren(code);
        return;
      }
      command.classList.add("copied");
      status.textContent = "Copied";
      clearTimeout(timer);
      timer = setTimeout(() => {
        command.classList.remove("copied");
        status.textContent = "";
      }, 2000);
    });
  }
}
