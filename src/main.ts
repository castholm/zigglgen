import { fetchRegistry } from "./fetchRegistry.js"
import { generateCode } from "./generateCode.js"
import { resolveFeatures } from "./resolveFeatures.js"

const registry = await fetchRegistry(new URL("../deps/gl.xml", import.meta.url))

const $loading = document.getElementById("loading")!
const $form = document.getElementById("form") as HTMLFormElement
const $apiVersionProfile = $form.querySelector("[name=api_version_profile]")! as HTMLSelectElement
const $extensions = $form.querySelector("[name=extension]")! as HTMLSelectElement
const $preview = document.getElementById("preview")!
const $previewOutlet = $preview.querySelector("code")!

let previousApi: string | null = null
$apiVersionProfile.addEventListener("change", () => {
  const [api] = $apiVersionProfile.value.split(",")
  if (api === previousApi) {
    return
  }
  previousApi = api ?? null
  const extensions = registry.apis.get(api!)!.extensions
  while ($extensions.firstChild) {
    $extensions.removeChild($extensions.lastChild!)
  }
  for (const extensionKey of extensions) {
    const extensionName = extensionKey.replace(/^GL_/, "")
    const $option = document.createElement("option")
    $option.value = extensionKey
    $option.textContent = extensionName
    $extensions.appendChild($option)
  }
})
$apiVersionProfile.dispatchEvent(new Event("change"))

$form.addEventListener("submit", e => {
  e.preventDefault()
  const [api, version, profile] = $apiVersionProfile.value.split(",")
  const extensions = [...$extensions.selectedOptions].map($ => $.value)
  const features = resolveFeatures(registry, api!, version!, profile ?? null, extensions)
  const code = generateCode(features, $apiVersionProfile.selectedOptions.item(0)!.textContent!)
  switch ((e.submitter as HTMLInputElement).value) {
  case "Preview":
    $preview.hidden = false
    $previewOutlet.textContent = code
    break
  case "Download":
    const $a = document.createElement("a")
    $a.href = URL.createObjectURL(new Blob([code], { type: "text/plain" }))
    $a.download = "gl.zig"
    $a.click()
    break
  }
})

$loading.hidden = true
$form.hidden = false
