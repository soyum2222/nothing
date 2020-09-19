---
title: "go 中的 Monkey Patching"
date: 2020-09-05T12:12:35+08:00
draft: false
---

翻译自 https://bou.ke/blog/monkey-patching-in-go/

很多人认为 monkey Patching 只能在动态语言中，像 Ruby 和 Python,但是并不是这样,计算机是一种愚蠢的机器,
我们始终能让他做我们所想的事情！让我们看下Go函数是如何工作的，以及如何在运行时修改它。这篇文章会使用大量的 intel 汇编，
所以我假设你已经掌握，或者在阅读时会参考查阅[相关资料](https://software.intel.com/en-us/articles/introduction-to-x64-assembly)。
	
如果你它如何工作的不感兴趣，并且你只想使用monkey 补丁 ，那么你可以找到[这个](https://github.com/bouk/monkey)库
	
让我看下反汇编后会是什么样子。
	
```
package main

func a() int { return 1 }

func main() {
  print(a())
}
```
	
通过Hopper编译后，我们看到上诉代码生成了这样的汇编。

![hopper](/images/hopper-1.png)


我将参考上面图片的左边展示的各种指令的地址。

我们的代码从main.main 开始，指令0x2010 到 0x2026 设置了栈。你可以通过[这里](https://dave.cheney.net/2013/06/02/why-is-a-goroutines-stack-infinite)获得更多关于此的信息。此文中，我将忽视这段代码。

0x202a处是在调用函数 main.a ，0x2000处 只是简单的把0x1移动到栈上 然后返回，0x202f到0x2037 则是将该值传递给函数runtime.printint。

非常简单！现在让我看下一个函数的值在go中是如何实现的。


##### 函数值在GO中的机制

```
package main

import (
  "fmt"
  "unsafe"
)

func a() int { return 1 }

func main() {
  f := a
  fmt.Printf("0x%x\n", *(*uintptr)(unsafe.Pointer(&f)))
}
```
	
	
在第11行我将函数a赋值给了f，这里的意思是执行f()的时候将调用函数a。然后我使用[unsafe](https://golang.org/pkg/unsafe/)包直接读处f存储的值。如果你有C语言的背景
你可能想到f是一个指向a的函数指针，然后因此这段代码打印出0x2000（上面的图片中main.a的位子），
当我在我的机器上运行后，我得到值0x102c38，
这是一个地址甚至不接近我们的代码！反编译后，这是上面代码第11行发生的事情:

![hopper2](/images/hopper-2.png)

它应用了一个叫main.a.f的东西，当我们看到main.a.f ，是下面这样:

![hopper3](/images/hopper-3.png)

哈！main.a.f 就是 0x102c38 他的值是 0x2000，这是main.a的地址。f 不像是一个函数的指针，但是他是一个函数指针的指针。
知道了这一点让我们来修改下代码。
	

	
```
package main
 
import (
  "fmt"
  "unsafe"
)
 
func a() int { return 1 }
 
func main() {
  f := a
  fmt.Printf("0x%x\n", **(**uintptr)(unsafe.Pointer(&f)))
}
```
	
	
现在打印了0x2000，符合预期。我们找到一个线索来解释为什么这里要这样实现，[点击这里](https://github.com/golang/go/blob/e9d9d0befc634f6e9f906b5ef7476fbd7ebd25e3/src/runtime/runtime2.go#L75-L78)。Go函数的值可以包含额外的信息，这就是闭包和
绑定函数的实现方式。
让我来看下，调用一个函数值是如何工作的。我将赋值后调用f
	
	
```
package main

func a() int { return 1 }

func main() {
	f := a
	f()
}
	
```
	
反编译后得到：
	
![hopper-4](/images/hopper-4.png)
	
main.a.f 指向的值被加载到rdx中，然后rdx指向的值被加载到rbx中,然后调用了rbx。函数值的地址总是加载到rdx中。
被调用的代码可以利用这点加载任何它所需要的额外信息。这些额外信息是指向一个绑定函数的实例和一个闭包的匿名函数。
如果你想了解得更多我建议你可以自己反编译去试一下。
	
	
#### 在运行时替换一个函数

我们想实现的是下面这段代码能打印出 数字2
	
```
package main

func a() int { return 1 }
func b() int { return 2 }

func main() {
	replace(a, b)
	print(a())
}
```
	
现在我们应该如何实现replace函数? 我们需要修改函数 a 跳转到 b 的代码，而不是执行a原本的代码主体。
实际上我们需要替换的是，将b的函数值加载到rdx 然后跳转到rdx所指向的地方。
	
```
	mov rdx, main.b.f ; 48 C7 C2 ?? ?? ?? ??
	jmp [rdx] ; FF 22
```
	
我把编译后生成机器代码写在旁边（你可以轻松的使用[在线汇编编辑器](https://defuse.ca/online-x86-assembler.htm)来编写汇编）。
编写一个生成这样代码的函数很简单，像这样：
	
```
func assembleJump(f func() int) []byte {
  funcVal := *(*uintptr)(unsafe.Pointer(&f))
  return []byte{
    0x48, 0xC7, 0xC2,
    byte(funcval >> 0),
    byte(funcval >> 8),
    byte(funcval >> 16),
    byte(funcval >> 24), // MOV rdx, funcVal
    0xFF, 0x22,          // JMP [rdx]
  }
}
```
	
	
	
现在我们一切就绪，我们需要替换a的函数体来跳转到b！
这段代码尝试将机器代码直接赋值到函数体的位子。
	
```
package main

import (
	"syscall"
	"unsafe"
)

func a() int { return 1 }
func b() int { return 2 }

func rawMemoryAccess(b uintptr) []byte {
	return (*(*[0xFF]byte)(unsafe.Pointer(b)))[:]
}

func assembleJump(f func() int) []byte {
	funcVal := *(*uintptr)(unsafe.Pointer(&f))
	return []byte{
		0x48, 0xC7, 0xC2,
		byte(funcVal >> 0),
		byte(funcVal >> 8),
		byte(funcVal >> 16),
		byte(funcVal >> 24), // MOV rdx, funcVal
		0xFF, 0x22,          // JMP [rdx]
	}
}

func replace(orig, replacement func() int) {
	bytes := assembleJump(replacement)
	functionLocation := **(**uintptr)(unsafe.Pointer(&orig))
	window := rawMemoryAccess(functionLocation)
	
	copy(window, bytes)
}

func main() {
	replace(a, b)
	print(a())
}
```
	
	
运行这段代码却不起作用，并且导致了分段错误。这是因为载入二进制在[默认情况下不可写](https://en.wikipedia.org/wiki/Segmentation_fault#Writing_to_read-only_memory)。
我们可以使用 mprotect syscall 来关闭这个保护，最后我就是这样做的，函数a被函数b替换了，并打印出了2
	
	
	
```
package main

import (
	"syscall"
	"unsafe"
)

func a() int { return 1 }
func b() int { return 2 }

func getPage(p uintptr) []byte {
	return (*(*[0xFFFFFF]byte)(unsafe.Pointer(p & ^uintptr(syscall.Getpagesize()-1))))[:syscall.Getpagesize()]
}

func rawMemoryAccess(b uintptr) []byte {
	return (*(*[0xFF]byte)(unsafe.Pointer(b)))[:]
}

func assembleJump(f func() int) []byte {
	funcVal := *(*uintptr)(unsafe.Pointer(&f))
	return []byte{
		0x48, 0xC7, 0xC2,
		byte(funcVal >> 0),
		byte(funcVal >> 8),
		byte(funcVal >> 16),
		byte(funcVal >> 24), // MOV rdx, funcVal
		0xFF, 0x22,          // JMP rdx
	}
}

func replace(orig, replacement func() int) {
	bytes := assembleJump(replacement)
	functionLocation := **(**uintptr)(unsafe.Pointer(&orig))
	window := rawMemoryAccess(functionLocation)
	
	page := getPage(functionLocation)
	syscall.Mprotect(page, syscall.PROT_READ|syscall.PROT_WRITE|syscall.PROT_EXEC)
	
	copy(window, bytes)
}

func main() {
	replace(a, b)
	print(a())
}
```
	
	
#### 封装成库

我把上边的代码放入了一个[易用的库中](https://github.com/bouk/monkey),它支持32位，反向修补程序和修补实例函数。我写了几个例子并把它们放在README中。
	
#### 最后
	
有志者事竟成！一个程序可以在运行时修改自己，这使得我们可以实现一些很酷的技巧，就像 monkey patching。
	
我希望你能从这篇文章学到一些对你有用的东西。
	
[原作者的 Hacker News ](https://news.ycombinator.com/item?id=9290917)
	
[原作者的 Reddit](https://www.reddit.com/r/golang/comments/30try1/monkey_patching_in_go/)
	
	
	
	
	
	
	
	
	
