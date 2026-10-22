document.querySelectorAll("button[data-copy]").forEach(function (button) {
  button.addEventListener("click", function () {
    var target = document.getElementById(button.dataset.copy), text = target.textContent;
    var done = function () { var label = button.textContent; button.textContent = button.dataset.done; setTimeout(function () { button.textContent = label; }, 1600); };
    var select = function () { var range = document.createRange(); range.selectNodeContents(target); var selection = getSelection(); selection.removeAllRanges(); selection.addRange(range); };
    if (navigator.clipboard) navigator.clipboard.writeText(text).then(done, select); else select();
  });
});
