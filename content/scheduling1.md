# GO 调度：part Ⅰ - 操作系统调度器

## 序言

这是三篇系列文章中的第一篇，这个系列文章会提供对GO调度器语义背后的理解，这篇文章着重于OS调度器

文章系列索引:

1)[Scheduling In Go : Part I - OS Scheduler](https://www.ardanlabs.com/blog/2018/08/scheduling-in-go-part1.html)
2)[Scheduling In Go : Part II - Go Scheduler](https://www.ardanlabs.com/blog/2018/08/scheduling-in-go-part2.html)
3)[Scheduling In Go : Part III - Concurrency](https://www.ardanlabs.com/blog/2018/12/scheduling-in-go-part3.html)


## 导言
GO 调度器的设计动机总是让你的多线程GO程序更加高效。这要感谢GO调度器对OS调度器的机械感知。
但是，你的多线程go软件的设计和动机对调度器的工作方式没有机器感知，这都不重要。
重要的是要有一个对OS和GO调度器如何工作有个代表性的理解，来正确的设计你的多线程软件。

这篇由多个部分组成的文章将集中讨论调度程序的高级机制和语义。我将提供足够的细节，让你直观地看到事情是如何运作的，
这样你就可以做出更好的工程决策。尽管对于多线程应用程序，您需要做的工程决策有很多内容，
但是机制和语义是您所需的基础知识的关键部分。


## OS 调度器

操作系统调度器是很复杂的。它们需要考虑它们所运行的硬件的规格，像多个处理器，[CPU缓存，NUMA等](http://frankdenneman.nl/2016/07/06/introduction-2016-numa-deep-dive-series)。
如果不懂这些知识，调度器将很难高效的工作。但是我们不深入讨论这些主题，还是可以从调度器的工作原理上学习到思想。

你的程序就是机器指令的集合，需要被有序的执行，为了做到这一点，操作系统引入了线程这个概念。线程的工作就是有序的执行分配给他的指令，
直到执行完后没有其他指令可以执行。这就是我为什么把线程叫做 “a path of execution”。

你的每个程序运行都会创建一个Process,每个Process都会初始化一个线程。线程还可以创建更多的线程。
每个线程彼此之间相互独立，调度的规则也是基于每个线程的优先级，不是基于Process的优先级。
线程们可以并发运行（每个线程都在一个处理器内核上），也可以并行（彼此运行在不同的内核上）。
线程还维护自己的状态，以保证安全，独立的执行本地的指令。

OS调度器需要在有线程可以调度的时候确保内核有事情可以干。它还必须假设，所有的可以执行的线程都在同一时间执行。同时，它还需要优先执行
优先级较高的线程，但是也要保证优先级低的线程不被饿死。调度器需要尽可能的用少的时间来做出优秀的决定，来减小调度延迟。

有很多的算法可以实现这一点，我们也拥有很多的经验。要更好的理解这些，需要定义一些重要的概念。

## 执行指令

程序计数器（PC），有时又叫指令指针（IP），它指向了线程下一次要执行的指令。在多处理器中，PC指向下一条指令，而不是当前指令

### Listing 1

![IP](/images/92_figure1.jpeg)

https://www.slideshare.net/JohnCutajar/assembly-language-8086-intermediate

如果你曾经看过GO的堆栈，你应该注意到每行的末尾有一个十六进制的数字，像这样 +0x39 和这样 +0x72 


```
goroutine 1 [running]:
   main.example(0xc000042748, 0x2, 0x4, 0x106abae, 0x5, 0xa)
       stack_trace/example1/example1.go:13 +0x39                 <- LOOK HERE
   main.main()
       stack_trace/example1/example1.go:8 +0x72                  <- LOOK HERE
```

这些数字代表PC寄存器的值从当前方法顶部的偏移值。PC +0x39 表示如果程序没有发生恐慌，线程执行example方法中的下一条指令。
PC + 0x75 表示当函数返回后，main方法将执行的吓一条指令。更重要的是，这个指针指向的指令的上一个指令，就是你当前正在执行的指令。

看下下面这个程序，它就是上面堆栈的源码。

### Listing 2
```
https://github.com/ardanlabs/gotraining/blob/master/topics/go/profiling/stack_trace/example1/example1.go

func main() {
    example(make([]string, 2, 4), "hello", 10)
}

func example(slice []string, str string, i int) {
   panic("Want stack trace")
}
```

PC 偏移 +0x38 表示example方法起始指令向下偏移57个字节（基于10进制）所得到的指令。在Listing 3 中，你可以从二进制中看到 example 的 objdump 。
找到第12条指令，注意这条指令上面那条指令是在调用 panic 

### Listing 3
```
$ go tool objdump -S -s "main.example" ./example1
TEXT main.example(SB) stack_trace/example1/example1.go
func example(slice []string, str string, i int) {
  0x104dfa0		65488b0c2530000000	MOVQ GS:0x30, CX
  0x104dfa9		483b6110		CMPQ 0x10(CX), SP
  0x104dfad		762c			JBE 0x104dfdb
  0x104dfaf		4883ec18		SUBQ $0x18, SP
  0x104dfb3		48896c2410		MOVQ BP, 0x10(SP)
  0x104dfb8		488d6c2410		LEAQ 0x10(SP), BP
	panic("Want stack trace")
  0x104dfbd		488d059ca20000	LEAQ runtime.types+41504(SB), AX
  0x104dfc4		48890424		MOVQ AX, 0(SP)
  0x104dfc8		488d05a1870200	LEAQ main.statictmp_0(SB), AX
  0x104dfcf		4889442408		MOVQ AX, 0x8(SP)
  0x104dfd4		e8c735fdff		CALL runtime.gopanic(SB)
  0x104dfd9		0f0b			UD2              <--- LOOK HERE PC(+0x39)
```

记住：PC寄存器的值是指向下一条指令，不是当前的指令。Listing 3 是一个在 amd64 基础上的一个很好的例子，改GO程序的线程按顺序指向指令。

## 线程状态

另一个重要的概念是线程状态，它规定了线程在调度器在线程中扮演的角色。一个线程可以处于三个种状态中的一种：等待，可运行，正在运行。

*等待*：这个状态意味着线程是停止的并且正在等待某些东西才能继续。这种状态可以是，等待硬件（硬盘，网络），等待操作系统（系统调用），
或者是同步调用（原子操作，互斥锁）。这种类型的延迟是导致性能差的根本原因。

*可运行*：这个状态意味着线程需要被调度到处理器上来执行分配给它的指令，如果你有很多线程都需要被调度，那么线程被调度就需要等待更长的时间。
而且，随着更多的线程竞争，每个线程被调度所得到的时间都将被缩短。这种类型的延时也是导致性能差的原因。

*正在运行*：这种状态意味着线程已经被调度到了处理器上，并且正在执行指令。这是每个线程都想到达的状态。

## 工作类型

线程有两种工作类型，一种是CPU密集型，一种是IO密集型。

*CPU密集型*：这种情况下线程永远不会处于等待状态。这种情况一直在进行计算。例如计算圆周率的线程就是CPU密集型的。

*IO密集型*：这是导致线程进入等待状态的原因。这种工作类型包括通过网络请求资源或者对操作系统进行系统调用，访问数据库，我认为还包含同步事件（互斥锁，原子操作），
因为这些操作都会让线程进入等待状态

## 上下文切换

如果你在Linux，MAC，Windows上运行，那么你就是运行在抢占式调度的系统上。有几点很重要。第一，调度程序选择运行哪个线程是不可预测的。
线程优先级和事件（例如从网络上接收数据）使得我们无法确定调度器将会选择何时以及如何调度。

第二，永远不要靠自己的感觉来写代码，就算你这次很幸运的对了，但是无法保证你每次都是幸运的。如果应用程序中需要确定性，那么你必须控制线程的同步。

在内核上线程切换的物理行为被称为上下文切换。调度器从内核中取出一个正在执行的线程，然后替换成一个准备运行的线程，就会发生上下文切换。
从准备运行的线程队列中选择出一个线程进入正在运行状态。被取出的线程会进入回到准备运行状态（如果它任然可以运行），或者进入到等待状态（如果它被替换下来的原因是因为IO请求）。

上下文切换是昂贵的，因为它需要时间在内核上做线程的交换


