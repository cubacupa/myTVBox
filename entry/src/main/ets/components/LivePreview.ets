import { media } from '@kit.MediaKit';

interface NoiseDot {
  x: number;
  y: number;
  c: string;
}

/**
 * 直播焦点卡的静音预览：同一时刻只允许一个实例存在。
 *
 * 这里刻意不复用 Player.ets 的完整播放器：那个播放器有字幕、音轨、续播、换线路、
 * 长按倍速等一大套逻辑，拿来做列表预览会把焦点卡拖成第二个播放页。预览只需要
 * 「有画面 / 没画面」两件事，所以状态机做到 prepared → play 就停。
 *
 * url 变化会重建播放器。旧实例的异步回调用 generation 挡掉，避免焦点连续移动时
 * 上一个频道的 initialized / playing 回调把新频道的画面顶掉。
 *
 * 没画面时不再是一块死黑：连接中显示雪花底 + 「连接中」，出错显示「信号中断」。
 * 预览真正播起来的线路通过 onStateChange 回传，播放页据此继承同一条线路。
 */
@Component
export struct LivePreview {
  @Prop @Watch('onUrlChanged') url: string = '';
  @State ready: boolean = false;
  @State phase: string = 'connecting';
  onStateChange: (phase: string, url: string) => void = () => {};
  private dots: NoiseDot[] = [];
  private xc: XComponentController = new XComponentController();
  private player: media.AVPlayer | null = null;
  private gen: number = 0;
  private surfaceId: string = '';
  private surfaceReady: boolean = false;
  private inited: boolean = false;
  private prepareCalled: boolean = false;
  // 每个实例一个独立 surface id。写死同一个 id 会让切台时新旧预览共绑一个 surface，
  // 旧播放器 release 是异步的，它的最后一帧会残留在 surface 上（表现为串台）。
  private xcId: string = 'livePreviewSurface_' + Math.floor(Math.random() * 1000000000).toString();

  aboutToAppear(): void {
    // 固定伪随机噪点，纯装饰，不依赖任何资源文件
    for (let i: number = 0; i < 72; i++) {
      const shade: string = i % 5 === 0 ? '#7A7D8A' : (i % 3 === 0 ? '#4A4D59' : '#292C36');
      this.dots.push({ x: (i * 47 + 13) % 100, y: (i * 73 + 29) % 100, c: shade });
    }
    this.open();
  }

  aboutToDisappear(): void {
    this.close();
  }

  private onUrlChanged(): void {
    this.ready = false;
    this.phase = 'connecting';
    this.close();
    this.open();
  }

  private close(): void {
    this.gen++;
    this.inited = false;
    this.prepareCalled = false;
    const p: media.AVPlayer | null = this.player;
    this.player = null;
    if (p !== null) {
      try {
        p.release().catch(() => {});
      } catch (e) {
        // 播放器已经失效时 release 会抛错，预览场景直接丢弃即可
      }
    }
  }

  private open(): void {
    const u: string = (this.url ?? '').trim();
    if (!u.startsWith('http')) {
      this.phase = 'error';
      this.onStateChange('error', u);
      return;
    }
    const g: number = ++this.gen;
    media.createAVPlayer().then((p: media.AVPlayer) => {
      if (g !== this.gen) {
        try {
          p.release().catch(() => {});
        } catch (e) {}
        return;
      }
      this.player = p;
      p.on('stateChange', (state: string) => {
        if (g !== this.gen) {
          return;
        }
        if (state === 'initialized') {
          this.inited = true;
          this.attach();
        } else if (state === 'prepared') {
          try {
            p.setVolume(0);
          } catch (e) {}
          p.setMediaMuted(media.MediaType.MEDIA_TYPE_AUD, true).catch(() => {});
          try {
            p.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT;
          } catch (e) {}
          try {
            p.play();
          } catch (e) {
            this.ready = false;
            this.phase = 'error';
            this.onStateChange('error', u);
          }
        } else if (state === 'playing') {
          this.ready = true;
          this.phase = 'playing';
          this.onStateChange('playing', u);
        } else if (state === 'released' || state === 'stopped' || state === 'idle') {
          this.ready = false;
        }
      });
      p.on('error', () => {
        if (g === this.gen) {
          this.ready = false;
          this.phase = 'error';
          this.onStateChange('error', u);
        }
      });
      try {
        p.url = u;
      } catch (e) {
        this.ready = false;
        this.phase = 'error';
        this.onStateChange('error', u);
      }
    }).catch(() => {
      if (g === this.gen) {
        this.ready = false;
        this.phase = 'error';
        this.onStateChange('error', u);
      }
    });
  }

  private attach(): void {
    const p: media.AVPlayer | null = this.player;
    if (p === null || !this.inited || !this.surfaceReady || this.prepareCalled) {
      return;
    }
    const sid: string = this.surfaceId.length > 0 ? this.surfaceId : this.xc.getXComponentSurfaceId();
    if (sid.length === 0) {
      return;
    }
    this.surfaceId = sid;
    this.prepareCalled = true;
    try {
      p.surfaceId = sid;
      p.prepare();
    } catch (e) {
      this.prepareCalled = false;
      this.ready = false;
      this.phase = 'error';
      this.onStateChange('error', this.url);
    }
  }

  build() {
    Stack() {
      XComponent({ id: this.xcId, type: XComponentType.SURFACE, controller: this.xc })
        .onLoad((sid: object) => {
          const got: string = String(sid ?? '');
          this.surfaceId = got.length > 0 ? got : this.xc.getXComponentSurfaceId();
          this.surfaceReady = this.surfaceId.length > 0;
          this.attach();
        })
        .onDestroy(() => {
          this.surfaceReady = false;
        })
        .focusable(false)
        .width('100%')
        .height('100%')

      if (this.phase !== 'playing') {
        Stack() {
          ForEach(this.dots, (dot: NoiseDot, idx: number) => {
            Row()
              .width(3)
              .height(3)
              .borderRadius(1.5)
              .backgroundColor(dot.c)
              .position({ x: dot.x.toString() + '%', y: dot.y.toString() + '%' })
          }, (dot: NoiseDot, idx: number) => 'n' + idx.toString())

          Column({ space: 10 }) {
            if (this.phase === 'connecting') {
              LoadingProgress().width(30).height(30).color('#FF8A3D')
              Text('连接中…')
                .fontSize(14)
                .fontColor('#C9CBD4')
            } else {
              Text('信号中断')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#D8D8E0')
            }
          }
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#151821')
      } else if (!this.ready) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#11131C')
      }
    }
    .width('100%')
    .height('100%')
    .borderRadius(14)
    .clip(true)
  }
}
