---
title: "Go 的时候发生了什么（1.15）"
date: 2020-09-13T14:40:37+08:00
draft: true
---

目前已经有很多大佬写过了MPG的文章，其中的文章要么就是不清不楚，要么就是大佬们放飞自我。导致👴看不懂。

所以说我准备自己来读一遍。

我们写go关键词的时候，编译器其实是把关键词给我们转换成了调用runtime.newproc函数

```
// Create a new g running fn with siz bytes of arguments.
// Put it on the queue of g's waiting to run.
// The compiler turns a go statement into a call to this.
//
// The stack layout of this call is unusual: it assumes that the
// arguments to pass to fn are on the stack sequentially immediately
// after &fn. Hence, they are logically part of newproc's argument
// frame, even though they don't appear in its signature (and can't
// because their types differ between call sites).
//
// This must be nosplit because this stack layout means there are
// untyped arguments in newproc's argument frame. Stack copies won't
// be able to adjust them and stack splits won't be able to copy them.
//
//go:nosplit
func newproc(siz int32, fn *funcval) {
	argp := add(unsafe.Pointer(&fn), sys.PtrSize)
	gp := getg()
	pc := getcallerpc()
	systemstack(func() {
		newg := newproc1(fn, argp, siz, gp, pc)

		_p_ := getg().m.p.ptr()
		runqput(_p_, newg, true)

		if mainStarted {
			wakep()
		}
	})

```

方法长这个样子,从上面的注释我们得到一个信息

fn参数其实是被go 函数的地址，该函数的参数被追加到了fn参数的末尾。

这一点其实很容易验证。我们写一个下面这样的方法。

```
func main() {

	go func(i string) {
		fmt.Println(i)
	}("123")

	time.Sleep(time.Hour)
}
```
然后反编译它，得到汇编。
```
...
	0x0024 00036 (some.go:7)	MOVL	$16, (SP)
	0x002b 00043 (some.go:7)	LEAQ	"".main.func1·f(SB), AX
	0x0032 00050 (some.go:7)	MOVQ	AX, 8(SP)
	0x0037 00055 (some.go:7)	LEAQ	go.string."123"(SB), AX
	0x003e 00062 (some.go:7)	MOVQ	AX, 16(SP)
	0x0043 00067 (some.go:7)	MOVQ	$3, 24(SP)
	0x004c 00076 (some.go:7)	PCDATA	$1, $0
	0x004c 00076 (some.go:7)	CALL	runtime.newproc(SB)
...
```

看到没有，字符串“123”的被追加到SP+16的位子，main.func1.f 在 SP+8的位子。

所以说第一行`argp := add(unsafe.Pointer(&fn), sys.PtrSize)` 就是把fn参数的起始地址偏移一个8字节，就是被go函数的参数的起始地址了。

这里sys.PtrSize也很有趣 `const PtrSize = 4 << (^uintptr(0) >> 63)` 如果是64位的话，满1 >> 63 后剩余1位，得到就是1，如果是32位这里得到就是0，由此来计算该机器的ptrsize，很有趣。跑题了。。

然后就是getg

```
// getg returns the pointer to the current g.
// The compiler rewrites calls to this function into instructions
// that fetch the g directly (from TLS or from the dedicated register).
func getg() *g
```

知道是获取当前的G，但是怎么获取嘛，我dlv了一下

```
        proc.go:3525            0xc0632a        65488b0c2528000000      mov rcx, qword ptr gs:[0x28]
        proc.go:3525            0xc06333        488b8900000000          mov rcx, qword ptr [rcx]

```

直接从内存中取的






