import { compare } from "./utils.js"

export type Registry = {
  readonly $root: Element
  readonly apis: ReadonlyMap<string, {
    readonly key: string
    readonly versions: readonly string[]
    readonly profiles: readonly string[]
    readonly extensions: readonly string[]
  }>
}

export async function fetchRegistry(url: string | URL): Promise<Registry> {
  const $root = await new Promise<Element>((resolve, reject) => {
    let xhr = new XMLHttpRequest()
    xhr.open("GET", url)
    xhr.responseType = "document"
    xhr.overrideMimeType("text/xml")
    xhr.onloadend = () => {
      if (xhr.status >= 200 && xhr.status < 300 && xhr.responseXML) {
        resolve(xhr.responseXML.documentElement)
      }
      reject(new Error("Failed to fetch registry."))
    }
    xhr.send()
  })
  return {
    $root,
    apis: new Map(["gl", "gles1", "gles2", "glsc2"].map(key => [key, {
      key,
      versions: [...new Set(
        [...$root.querySelectorAll(`:scope > feature[api=${key}]`)]
          .map($ => $.getAttribute("number")!),
      )].sort(compare),
      profiles: [...new Set(
        [...$root.querySelectorAll(`:scope > feature[api=${key}] > *[profile]`)]
          .map($ => $.getAttribute("profile")!),
      )].sort(compare),
      extensions: [...new Set(
        [...$root.querySelectorAll(":scope > extensions > extension")]
          .filter($ => $.getAttribute("supported")!.split("|").includes(key))
          .map($ => $.getAttribute("name")!),
      )].sort(compare),
    }])),
  }
}
