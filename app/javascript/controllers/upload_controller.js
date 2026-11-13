import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form", "file"]

  disconnect() {
    document.body.classList.remove("upload-dragging")
  }

  select() {
    this.fileTarget.click()
  }

  submit() {
    if (this.fileTarget.files.length) this.formTarget.requestSubmit()
  }

  highlight(event) {
    if (!Array.from(event.dataTransfer.types).includes("Files")) return
    event.preventDefault()
    document.body.classList.add("upload-dragging")
  }

  unhighlight(event) {
    if (!event.relatedTarget) document.body.classList.remove("upload-dragging")
  }

  drop(event) {
    event.preventDefault()
    document.body.classList.remove("upload-dragging")
    const file = event.dataTransfer.files[0]
    if (!file) return
    const transfer = new DataTransfer()
    transfer.items.add(file)
    this.fileTarget.files = transfer.files
    this.submit()
  }
}
