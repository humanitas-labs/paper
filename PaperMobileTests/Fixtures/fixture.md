# Paper on a phone

A paragraph with **bold**, *italic*, ***both***, `inline code`, ~~struck~~, <u>underlined</u> and a [link](https://example.com). It runs long enough to wrap across several lines on a narrow screen, so the measure and the margins show. An arrow -> turns into one.

## Lists

- A dashed item
- Another, with a nested list:
  - Nested one
  - Nested two
* A bulleted item

1. First
2. Second
3. Third

- [ ] An open task
- [x] A done task
  - [ ] A nested open task

> A block quote that is long enough to wrap onto a second line, so the rule runs the height of both.

---

### Code

```swift
let page = PaperLayoutManager()
print("hello")
```

### A table

| Construct | Where it draws | Notes |
|---|---|---|
| Code band | Behind the text | Rounded |
| Table cell | In the concealed row | Wraps to its column when the text is long |
| Image | In the band under its line | Fitted to the measure |

### Math

Inline math such as $e^{i\pi} + 1 = 0$ sits on the baseline.

$$
\int_0^1 x^2 \, dx = \frac{1}{3}
$$

### An image

![The enso](enso.png)

The end.
