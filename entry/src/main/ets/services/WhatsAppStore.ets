/**
 * Sample content for the shell. It is deliberately realistic and complete so
 * the app is usable before WhatsApp is configured, matching the "honest
 * offline fallback" principle of the Harmony X reference.
 */
import { Theme } from '../styles/Theme';
import { ChatItem, MessageItem, StatusItem, ChannelItem, CallItem, CommunityItem } from '../models/WhatsAppModels';

function chat(id: string, name: string, preview: string, time: string, unread: number,
  group: boolean = false, online: boolean = false): ChatItem {
  const c = new ChatItem();
  c.id = id;
  c.name = name;
  c.preview = preview;
  c.time = time;
  c.unread = unread;
  c.isGroup = group;
  c.online = online;
  return c;
}

function msg(chatId: string, id: string, text: string, time: string, out: boolean, status: string = ''): MessageItem {
  const m = new MessageItem();
  m.chatId = chatId;
  m.id = id;
  m.text = text;
  m.time = time;
  m.out = out;
  m.status = status;
  return m;
}

export class WhatsAppStore {
  static sampleChats(): ChatItem[] {
    return [
      chat('maya@s.whatsapp.net', 'Maya Chen', 'The new motion pass feels much calmer. Ship it?', '09:42', 2, false, true),
      chat('design@s.whatsapp.net', 'Design Crew', 'Leo: I pushed the updated tokens to the board', '09:31', 5, true),
      chat('dad@s.whatsapp.net', 'Dad', 'Call me when you get a minute, nothing urgent', 'Yesterday', 1),
      chat('aisha@s.whatsapp.net', 'Aisha Rahman', 'Photo · Thanks for the walk!', 'Yesterday', 0),
      chat('launch@s.whatsapp.net', 'Product Launch', 'Nina: final checklist is in the doc', 'Tue', 0, true),
      chat('runners@s.whatsapp.net', 'Sunday Runners', 'Sam: 7am at the bridge, bring water', 'Tue', 0, true),
      chat('nina@s.whatsapp.net', 'Nina Park', 'Sent you the notes from the review', 'Mon', 0),
      chat('bookclub@s.whatsapp.net', 'Book Club', 'Next pick: The Left Hand of Darkness', 'Mon', 3, true),
      chat('leo@s.whatsapp.net', 'Leo Martins', 'That icon set is so good', 'Sun', 0),
      chat('whatsapp@s.whatsapp.net', 'WhatsApp', 'Your account is now linked to this device', 'Sun', 0),
    ];
  }

  static sampleMessages(chatId: string, chatName: string): MessageItem[] {
    const base: string = chatId.length > 0 ? chatId : chatName;
    const common: MessageItem[] = [
      msg(base, base + '-1', 'Hey! How is the new build feeling?', '09:12', false),
      msg(base, base + '-2', 'Much better. The tabs finally make sense.', '09:14', true, 'read'),
      msg(base, base + '-3', 'The compose action is a nice touch too.', '09:16', false),
      msg(base, base + '-4', 'Thanks. I kept it out of the way of the tab bar.', '09:18', true, 'read'),
      msg(base, base + '-5', 'Can you send the latest screens when you get a chance?', '09:22', false),
      msg(base, base + '-6', 'Just uploaded them to the shared folder.', '09:25', true, 'delivered'),
      msg(base, base + '-7', 'Perfect. The dark mode contrast looks right.', '09:28', false),
      msg(base, base + '-8', 'Agreed. I also fixed the unread pill.', '09:31', true, 'read'),
      msg(base, base + '-9', 'Ship it.', '09:33', false),
    ];
    if (chatName === 'Maya Chen') {
      return [
        msg(base, base + '-a', 'The new motion pass feels much calmer.', '09:38', false),
        msg(base, base + '-b', 'It does. I reduced the spring on the sheet.', '09:39', true, 'read'),
        msg(base, base + '-c', 'Ship it?', '09:42', false),
      ];
    }
    return common;
  }

  static sampleStatuses(): StatusItem[] {
    const names: string[] = ['Maya Chen', 'Leo Martins', 'Aisha Rahman', 'Dad', 'Nina Park'];
    const texts: string[] = ['Studio light', 'New icons', 'Evening walk', 'Garden', 'Reading list'];
    const out: StatusItem[] = [];
    for (let i = 0; i < names.length; i++) {
      const s = new StatusItem();
      s.id = 'status-' + i;
      s.name = names[i];
      s.time = i === 0 ? '12m' : (i + 1) + 'h';
      s.text = texts[i];
      s.viewed = i > 2;
      s.color = Theme.avatarColor(names[i]);
      out.push(s);
    }
    return out;
  }

  static sampleChannels(): ChannelItem[] {
    const names: string[] = ['WhatsApp Updates', 'HarmonyOS Design', 'Sunday Runners'];
    const descriptions: string[] = ['Product news and tips', 'Patterns for adaptive apps', 'Routes, photos and meetups'];
    const followers: number[] = [1200000, 48000, 312];
    const out: ChannelItem[] = [];
    for (let i = 0; i < names.length; i++) {
      const c = new ChannelItem();
      c.id = 'channel-' + i;
      c.name = names[i];
      c.description = descriptions[i];
      c.followers = followers[i];
      c.unread = i === 0 ? 2 : 0;
      out.push(c);
    }
    return out;
  }

  static sampleCalls(): CallItem[] {
    const rows: string[][] = [
      ['Maya Chen', 'video', 'in', '0', '09:05'],
      ['Dad', 'voice', 'in', '1', 'Yesterday'],
      ['Design Crew', 'voice', 'out', '0', 'Yesterday'],
      ['Aisha Rahman', 'video', 'out', '0', 'Tue'],
      ['Nina Park', 'voice', 'in', '0', 'Mon'],
    ];
    const out: CallItem[] = [];
    for (let i = 0; i < rows.length; i++) {
      const c = new CallItem();
      c.id = 'call-' + i;
      c.name = rows[i][0];
      c.video = rows[i][1] === 'video';
      c.incoming = rows[i][2] === 'in';
      c.missed = rows[i][3] === '1';
      c.time = rows[i][4];
      out.push(c);
    }
    return out;
  }

  static sampleCommunities(): CommunityItem[] {
    const rows: string[][] = [
      ['Design Systems', 'A place for tokens, components and critique', '1280'],
      ['Neighbourhood', 'Local notices, recommendations and meetups', '684'],
      ['Sunday Runners', 'Weekly routes and race photos', '312'],
      ['Photography Club', 'Monthly challenges and shared galleries', '940'],
    ];
    const out: CommunityItem[] = [];
    for (let i = 0; i < rows.length; i++) {
      const c = new CommunityItem();
      c.id = 'community-' + i;
      c.name = rows[i][0];
      c.description = rows[i][1];
      c.members = Number(rows[i][2]);
      c.unread = i === 0 ? 4 : 0;
      c.joined = i < 2;
      out.push(c);
    }
    return out;
  }
}
