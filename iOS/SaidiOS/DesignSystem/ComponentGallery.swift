import SwiftUI
import SaidKit

/// Every §7 component on one screen. Not shipped in the tab order — it exists so the design system
/// can be verified visually (and screenshotted) before any real screen composes from it.
struct ComponentGallery: View {
    @State private var tab: RecordDock.Tab = .library

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.windowBG.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("Said").font(Theme.ui(36, weight: .semibold))
                        Text(".").font(Theme.ui(36, weight: .semibold)).foregroundStyle(Palette.amber)
                    }

                    SectionRule(title: "Blobs")
                    HStack(spacing: 14) {
                        Blob(size: 44, color: Palette.violet)
                        Blob(size: 30, color: Palette.amber)
                        Blob(size: 18, color: Palette.ink)
                        BlobPair(size: 20)
                            .padding(10).background(Palette.violet)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }

                    SectionRule(title: "Chips")
                    HStack(spacing: 8) {
                        Chip(text: "All 42", kind: .on)
                        Chip(text: "Lectures", kind: .violet)
                        Chip(text: "Meetings", kind: .amber)
                        Chip(text: "Imported", kind: .neutral)
                    }

                    SectionRule(title: "Sticker card")
                    StickerCard {
                        HStack(spacing: 14) {
                            BlobPair(size: 12)
                                .frame(width: 44, height: 44)
                                .background(Palette.amber)
                                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Sprint planning — week 33")
                                    .font(Theme.ui(16, weight: .semibold))
                                HStack(spacing: 6) {
                                    Text("24 min").font(Theme.ui(13)).foregroundStyle(Theme.text2)
                                    SpeakerDot(slot: 1); SpeakerDot(slot: 2); SpeakerDot(slot: 3)
                                }
                            }
                            Spacer(minLength: 0)
                            MonoTime(seconds: 1446)
                        }
                        .padding(15)
                    }

                    SectionRule(title: "Buttons")
                    VStack(spacing: 12) {
                        PressedButton(kind: .violet) {} label: {
                            Text("Let Said hear you").font(Theme.ui(16, weight: .semibold))
                        }
                        PressedButton(kind: .amber) {} label: {
                            Text("Done").font(Theme.ui(16, weight: .semibold))
                        }
                        PressedButton(kind: .ink) {} label: {
                            Text("Something already recorded").font(Theme.ui(16, weight: .semibold))
                        }
                    }

                    SectionRule(title: "Speakers")
                    HStack(spacing: 10) {
                        ForEach(1...8, id: \.self) { slot in
                            VStack(spacing: 5) {
                                SpeakerDot(slot: slot, size: 20)
                                Text("\(slot)").font(Theme.mono(9)).foregroundStyle(Theme.text3)
                            }
                        }
                    }

                    Color.clear.frame(height: 90)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }

            RecordDock(tab: $tab) {}
        }
    }
}
