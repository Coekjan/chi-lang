// The project function defines how your document looks.
// It takes your content and some metadata and formats it.
// Go ahead and customize it to your liking!
#let project(title: "", authors: (), logo: none, body) = {
  // Set the document's basic properties.
  set document(author: authors.map(a => a.name), title: title)
  set page(numbering: "1", number-align: center)
  set text(font: ("Times New Roman"), lang: "zh")
  set ref(supplement: it => {
    if it.func() == heading {
      [§]
    } else {
      it.fields().supplement
    }
  })
  set heading(numbering: "§ 1.1.1")
  set par(first-line-indent: 2em)

  show regex("[\u4e00-\u9fa5]+"): set text(
    font: ("SimSun"),
    lang: "zh"
  )

  show heading: it => [
    #if it.level == 1 {
      pagebreak(weak: true)
      align(center, it)
    } else {
      it
    }
    #if it.outlined {
      par[#text(size:0.0em)[#h(0.0em)]]
    }
  ]

  // Title page.
  // The page can contain a logo if you pass one with `logo: "logo.png"`.
  v(0.6fr)
  if logo != none {
    align(right, image(logo, width: 26%))
  }
  v(9.6fr)

  text(2em, weight: 700, title)

  // Author information.
  pad(
    top: 0.7em,
    right: 20%,
    grid(
      columns: (1fr,) * calc.min(3, authors.len()),
      gutter: 1em,
      ..authors.map(author => align(start)[
        *#author.name* \
        #author.email \
        #author.affiliation
      ]),
    ),
  )

  v(2.4fr)
  pagebreak()


  // Table of contents.
  outline(depth: 3, indent: true)
  pagebreak()


  // Main body.
  set par(justify: true)

  body
}